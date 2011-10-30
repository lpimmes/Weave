/*
Weave (Web-based Analysis and Visualization Environment)
Copyright (C) 2008-2011 University of Massachusetts Lowell

This file is a part of Weave.

Weave is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License, Version 3,
as published by the Free Software Foundation.

Weave is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Weave. If not, see <http://www.gnu.org/licenses/>.
*/

package weave.ui
{
	import flash.display.DisplayObject;
	import flash.display.Graphics;
	import flash.events.ContextMenuEvent;
	import flash.events.MouseEvent;
	import flash.geom.Point;
	import flash.ui.ContextMenu;
	import flash.ui.ContextMenuItem;
	import flash.utils.Dictionary;
	
	import mx.core.Application;
	import mx.core.UIComponent;
	import mx.core.mx_internal;
	import mx.events.FlexEvent;
	import mx.events.ResizeEvent;
	import mx.managers.CursorManagerPriority;
	
	import weave.Weave;
	import weave.api.WeaveAPI;
	import weave.api.core.IDisposableObject;
	import weave.api.core.ILinkableContainer;
	import weave.api.core.ILinkableObject;
	import weave.api.data.IQualifiedKey;
	import weave.api.getCallbackCollection;
	import weave.api.primitives.IBounds2D;
	import weave.api.registerLinkableChild;
	import weave.api.ui.IPlotLayer;
	import weave.compiler.StandardLib;
	import weave.core.LinkableNumber;
	import weave.core.LinkableString;
	import weave.core.StageUtils;
	import weave.data.KeySets.KeySet;
	import weave.primitives.Bounds2D;
	import weave.primitives.SimpleGeometry;
	import weave.utils.CustomCursorManager;
	import weave.utils.SpatialIndex;
	import weave.visualization.layers.PlotLayerContainer;
	import weave.visualization.tools.SimpleVisTool;

	use namespace mx_internal;
	
	/**
	 * This is a class that controls the graphical annotations within Weave.
	 * 
	 * @author jfallon
	 * @author adufilie
	 * @author kmonico
	 */
	public class PenTool extends UIComponent implements ILinkableObject, IDisposableObject
	{
		// TODO: Refactor into separate classes for free draw and polygonal drawing?
		public function PenTool()
		{
			percentWidth = 100;
			percentHeight = 100;
			
			// add local event listeners for rollOver/rollOut for changing the cursor
			addEventListener(MouseEvent.MOUSE_OVER, handleRollOver);
			addEventListener(MouseEvent.MOUSE_OUT, handleRollOut);
			// add local event listener for mouse down. local rather than global because we don't care if mouse was pressed elsewhere
			addEventListener(MouseEvent.MOUSE_DOWN, handleMouseDown);

			addEventListener(FlexEvent.CREATION_COMPLETE, handleCreationComplete);

			// enable the double click event
			doubleClickEnabled = true;
			addEventListener(MouseEvent.DOUBLE_CLICK, handleDoubleClick);
			
			// add global event listener for mouse move and mouse up because user may move or release outside this display object
			StageUtils.addEventCallback(MouseEvent.MOUSE_MOVE, this, handleMouseMove);
			StageUtils.addEventCallback(MouseEvent.MOUSE_UP, this, handleMouseUp);
 
			setupMask();
		}


		/**
		 * Setup the clipping mask which is used to keep the pen drawings on screen.
		 */		
		private function setupMask():void
		{
			// when this component is resized, the mask needs to be updated
			var handleResize:Function = function (event:ResizeEvent):void
			{
				var penTool:PenTool = event.target as PenTool;
				
				// clear the mask graphics
				_maskObject.graphics.clear();

				// percent width and height seems off sometimes...
				_maskObject.width = parent.width;
				_maskObject.height = parent.height;
				_maskObject.invalidateSize();
				_maskObject.validateNow();
				
				// and draw the invisible rectangle (invisible because mask.visible = false)
				_maskObject.graphics.beginFill(0xFFFFFF, 1);
				_maskObject.graphics.drawRect(0, 0, parent.width, parent.height);
				_maskObject.graphics.endFill();
			}
			addEventListener(ResizeEvent.RESIZE, handleResize);
			
			_maskObject.visible = false;
			mask = _maskObject;
			addChild(_maskObject);
			
			_maskObject.percentWidth = 100;
			_maskObject.percentHeight = 100;
		}
		
		private function handleCreationComplete(event:FlexEvent):void
		{
			// when the visualization changes, the dataBounds may have changed
			var visualization:PlotLayerContainer = getPlotLayerContainer(parent);
			if (visualization)
			{
				var handleContainerChange:Function = function ():void
				{
					invalidateDisplayList();
				};

				getCallbackCollection(visualization).addGroupedCallback(this, handleContainerChange);
			}
			
			// when the drawingMode changes, remove all the points from coords
			var removeDrawings:Function = function ():void
			{
				coords.value = ""; 
			}
			drawingMode.addGroupedCallback(this, removeDrawings, false);
		}

		public function dispose():void
		{
			editMode = false; // public setter cleans up event listeners and cursor
		}
		
		private const _maskObject:UIComponent = new UIComponent();
		private var _editMode:Boolean = false; // true when editing
		private var _drawing:Boolean = false; // true when editing and mouse is down
		private var _coordsArrays:Array = []; // parsed from coords LinkableString
		public const drawingMode:LinkableString = new LinkableString(FREE_DRAW_MODE, verifyDrawingMode);
		
		/**
		 * This is used for sessioning all of the coordinates.
		 */
		public const coords:LinkableString = registerLinkableChild(this, new LinkableString(''), handleCoordsChange);
		/**
		 * Allows user to change the size of the line.
		 */
		public const lineWidth:LinkableNumber = registerLinkableChild(this, new LinkableNumber(2), invalidateDisplayList);
		/**
		 * Allows the user to change the color of the line.
		 */
		public const lineColor:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0x000000), invalidateDisplayList);
		
		public function get editMode():Boolean
		{
			return _editMode;
		}

		public function set editMode(value:Boolean):void
		{
			if (_editMode == value)
				return;
			
			_editMode = value;
			
			_drawing = false;
			if (value)
				CustomCursorManager.showCursor(CustomCursorManager.PEN_CURSOR, CursorManagerPriority.HIGH, -3, -22);
			else
				CustomCursorManager.removeAllCursors();
			invalidateDisplayList();
		}

		private function verifyDrawingMode(value:String):Boolean
		{
			return value == FREE_DRAW_MODE || value == POLYGON_DRAW_MODE;
		}

		/**
		 * Handle a screen coordinate and project it into the data bounds of the parent visualization. 
		 * @param x The x value in screen coordinates.
		 * @param y The y value in screen coordinates.
		 * @param output The point to store the data projected point.
		 */		
		private function handleScreenCoordinate(x:Number, y:Number, output:Point):void
		{
			var visualization:PlotLayerContainer = getPlotLayerContainer(parent);
			if (visualization)
			{
				visualization.zoomBounds.getScreenBounds(_tempScreenBounds);				
				visualization.zoomBounds.getDataBounds(_tempDataBounds);
				
				output.x = x;
				output.y = y;
				_tempScreenBounds.projectPointTo(output, _tempDataBounds);					
			}
		}
		
		/**
		 * Handle a data coordinate and project it into the screen bounds of the parent visualization. 
		 * @param x1 The x value in data coordiantes.
		 * @param y1 The y value in data coordinates.
		 * @param output The point to store the screen projected point.
		 */		
		private function projectCoordToScreenBounds(x1:Number, y1:Number, output:Point):void
		{
			var linkableContainer:ILinkableContainer = getLinkableContainer(parent);
			var visualization:PlotLayerContainer = (linkableContainer as SimpleVisTool).visualization as PlotLayerContainer;
			if (visualization)
			{
				visualization.zoomBounds.getScreenBounds(_tempScreenBounds);				
				visualization.zoomBounds.getDataBounds(_tempDataBounds);
				
				// project the point to screen bounds
				output.x = x1;
				output.y = y1;
				_tempDataBounds.projectPointTo(output, _tempScreenBounds);
				
				// get the rounded values
				var x2:Number = Math.round(output.x);
				var y2:Number = Math.round(output.y);
				
				output.x = x2;
				output.y = y2;
			}
		}

		/**
		 * This is the callback of <code>coords</code> 
		 */		
		private function handleCoordsChange():void
		{
			if (!_drawing)
				_coordsArrays = WeaveAPI.CSVParser.parseCSV( coords.value );
			invalidateDisplayList();
		}

		/**
		 * This function is called when the left mouse button is pressed inside the PenTool UIComponent.
		 * It adds the initial mouse position coordinate to the session state so it knows where
		 * to start from for the following lineTo's added to it.
		 */
		private function handleMouseDown(event:MouseEvent):void
		{
			var line:Array;

			if (!_editMode || mouseOffscreen())
				return;
			
			// project the point to data coordinates
			handleScreenCoordinate(mouseX, mouseY, _tempPoint);
			
			if (drawingMode.value == FREE_DRAW_MODE)
			{
				// begin a new line and save the point. Note that _drawing is true
				// to avoid parsing coords.value
				_drawing = true;
				coords.value += '\n' + _tempPoint.x + "," + _tempPoint.y + ",";
				_coordsArrays.push([_tempPoint.x, _tempPoint.y]);
			}
			else if (drawingMode.value == POLYGON_DRAW_MODE)
			{
				if (_drawing && _coordsArrays.length >= 1) 
				{
					// continue last line
					coords.value += _tempPoint.x + "," + _tempPoint.y + ",";
					
					line = _coordsArrays[_coordsArrays.length - 1];
					line.push(_tempPoint.x, _tempPoint.y);
				}
				else // begin a line
				{
					// To simplify the code, append the same "x,y," string to coords.value
					// and then manually push the values into _coordsArrays. If we let the 
					// coords callback parse coords.value, then _coordsArrays will have an element
					// "" at index 2 for the new line, which will put "" into _coordsArray[line][2] and
					// this is cast to 0 during drawing.
					_drawing = true;

					coords.value += '\n' + _tempPoint.x + "," + _tempPoint.y + ",";
				
					line = [];
					line.push(_tempPoint.x, _tempPoint.y);
					_coordsArrays.push(line);
				}
			}
			
			// redraw
			invalidateDisplayList();
		}
		
		/**
		 * Handle a double click event which is used for ending the polygon drawing. 
		 * @param event The mouse event.
		 */		
		private function handleDoubleClick(event:MouseEvent):void
		{
			if (_drawing && drawingMode.value == POLYGON_DRAW_MODE)
			{
				var line:Array = _coordsArrays[_coordsArrays.length - 1];
				if (line && line.length > 2)
				{
					line.push(line[0], line[1]);
					coords.value += line[0] + "," + line[1]; // this ends the line
				}
				_drawing = false;
			}
		}
		
		/**
		 * Handle the mouse release event. 
		 */		
		private function handleMouseUp():void
		{
			if (!_editMode || mouseOffscreen())
				return;

			if (drawingMode.value == FREE_DRAW_MODE)
			{
				_drawing = false;
			}
			else if (drawingMode.value == POLYGON_DRAW_MODE)
			{
				// when in polygon draw mode, we are still drawing after letting go of mouse1
				var line:Array = _coordsArrays[_coordsArrays.length - 1];
				var x:Number = StandardLib.constrain(mouseX, 0, unscaledWidth);
				var y:Number = StandardLib.constrain(mouseY, 0, unscaledHeight);

				handleScreenCoordinate(x, y, _tempPoint);
				line.push(_tempPoint.x, _tempPoint.y);
				coords.value += _tempPoint.x + "," + _tempPoint.y + ",";
			}

			// redraw
			invalidateDisplayList();
		}
		
		/**
		 * Handle a mouse move event. 
		 */		
		private function handleMouseMove():void
		{
			if (_drawing && editMode && !mouseOffscreen())
			{
				// we're drawing and on the screen, so get the value for the point
				var x:Number = StandardLib.constrain(mouseX, 0, unscaledWidth);
				var y:Number = StandardLib.constrain(mouseY, 0, unscaledHeight);
				
				// get the current line
				var line:Array = _coordsArrays[_coordsArrays.length - 1];
				// only save new coords if they are different from previous coordinates
				// and we're in free_draw_mode
				if (drawingMode.value == FREE_DRAW_MODE &&  
					(line.length < 2 || line[line.length - 2] != x || line[line.length - 1] != y))
				{
					handleScreenCoordinate(x, y, _tempPoint);
					line.push(_tempPoint.x, _tempPoint.y);
					coords.value += _tempPoint.x + "," + _tempPoint.y + ",";
				}
			}
			
			// redraw
			invalidateDisplayList();
		}
		
		/**
		 * Show the pen cursor if we are in edit mode. 
		 * @param e The mouse event.
		 */		
		private function handleRollOver(e:MouseEvent):void
		{
			if (!_editMode)
				return;
			
			CustomCursorManager.showCursor(CustomCursorManager.PEN_CURSOR, CursorManagerPriority.HIGH, -3, -22);
		}
		
		/**
		 * Remove the mouse cursor if we are in edit mode.
		 * @param e The mosue event.
		 */		
		private function handleRollOut( e:MouseEvent ):void
		{
			if (!_editMode)
				return;
			
			CustomCursorManager.removeAllCursors();
		}
		
		override protected function updateDisplayList(unscaledWidth:Number, unscaledHeight:Number):void
		{
			super.updateDisplayList(unscaledWidth, unscaledHeight);
			
			var visualization:PlotLayerContainer = getPlotLayerContainer(parent); 
			if (visualization) 
			{
				var g:Graphics = graphics;
				g.clear();
				
				if (_editMode)
				{
					// draw invisible rectangle to capture mouse events
					g.lineStyle(0, 0, 0);
					g.beginFill(0, 0);
					g.drawRect(0, 0, unscaledWidth, unscaledHeight);
					g.endFill();
				}
				
				g.lineStyle(lineWidth.value, lineColor.value);
				for (var line:int = 0; line < _coordsArrays.length; line++)
				{
					var points:Array = _coordsArrays[line];
					for (var i:int = 0; i < points.length - 1 ; i += 2 )
					{
						var x:Number = points[i];
						var y:Number = points[i+1];

						projectCoordToScreenBounds(x, y, _tempPoint);
						
						if (i == 0)
							g.moveTo(_tempPoint.x, _tempPoint.y);
						else
							g.lineTo(_tempPoint.x, _tempPoint.y);
					}
				}
				
				if (_drawing && drawingMode.value == POLYGON_DRAW_MODE)
				{
					g.lineTo(mouseX, mouseY);
				}
			}
		}

		/**
		 * Check if the mouse if off the tool. 
		 * @return <code>true</code> if the mouse is outside the parent coordinates.
		 */		
		private function mouseOffscreen():Boolean
		{
			return mouseX < parent.x || mouseX >= parent.x + parent.width
				|| mouseY < parent.y || mouseY >= parent.y + parent.height;
		}
				
		/**
		 * This function will check for records overlapping each drawn polygon. The keys
		 * will then be set to the defaultSelectionFilter.
		 */		
		public function selectRecords():void
		{
			if (drawingMode.value == FREE_DRAW_MODE)
				return;
			
			var visualization:PlotLayerContainer = getPlotLayerContainer(parent);
			if (!visualization)
				return;
			
			var key:IQualifiedKey;
			var keys:Dictionary = new Dictionary();
			var layers:Array = visualization.layers.getObjects();
			for each (var layer:IPlotLayer in layers)
			{
				var spatialIndex:SpatialIndex = layer.spatialIndex as SpatialIndex;
				var shapes:Array = WeaveAPI.CSVParser.parseCSV(coords.value);
				for each (var shape:Array in shapes)
				{
					_tempArray.length = 0;
					for (var i:int = 0; i < shape.length - 1; i += 2)
					{
						var newPoint:Point = new Point();
						newPoint.x = shape[i];
						newPoint.y = shape[i + 1];
						_tempArray.push(newPoint);
					}
					_simpleGeom.setVertices(_tempArray);
					var overlappingKeys:Array = spatialIndex.getKeysGeometryOverlapGeometry(_simpleGeom);
					for each (key in overlappingKeys)
					{
						keys[key] = true;
					}				
				}
			}

			// set the selection keyset
			var selectionKeySet:KeySet = Weave.root.getObject(Weave.DEFAULT_SELECTION_KEYSET) as KeySet;
			_tempArray.length = 0;
			for (var keyObj:* in keys)
			{
				_tempArray.push(keyObj as IQualifiedKey);
			}
			selectionKeySet.replaceKeys(_tempArray);
		}
		private const _tempArray:Array = [];
		private const _simpleGeom:SimpleGeometry = new SimpleGeometry(SimpleGeometry.CLOSED_POLYGON);
		private const _tempScreenBounds:IBounds2D = new Bounds2D();
		private const _tempDataBounds:IBounds2D = new Bounds2D();
		private const _tempPoint:Point = new Point();
		
		/*************************************************/
		/** static section                              **/
		/*************************************************/
		
		private static var _penToolMenuItem:ContextMenuItem = null;
		private static var _removeDrawingsMenuItem:ContextMenuItem = null;
		private static var _changeDrawingMode:ContextMenuItem = null;
		private static var _selectRecordsMenuItem:ContextMenuItem = null;
		private static const ENABLE_PEN:String = "Enable Pen Tool";
		private static const DISABLE_PEN:String = "Disable Pen Tool";
		private static const REMOVE_DRAWINGS:String = "Remove All Drawings";
		private static const CHANGE_DRAWING_MODE:String = "Change Drawing Mode";
		private static const PEN_OBJECT_NAME:String = "penTool";
		public static const FREE_DRAW_MODE:String = "Free Draw Mode";
		public static const POLYGON_DRAW_MODE:String = "Polygon Draw Mode";
		private static const SELECT_RECORDS:String = "Select Records in Polygon";
		private static const _menuGroupName:String = "5 drawingMenuitems";
		public static function createContextMenuItems(destination:DisplayObject):Boolean
		{
			if (!destination.hasOwnProperty("contextMenu"))
				return false;
			
			// Add a listener to this destination context menu for when it is opened
			var contextMenu:ContextMenu = destination["contextMenu"] as ContextMenu;
			contextMenu.addEventListener(ContextMenuEvent.MENU_SELECT, handleContextMenuOpened);

			// Create a context menu item for printing of a single tool with title and logo
			_penToolMenuItem = CustomContextMenuManager.createAndAddMenuItemToDestination(ENABLE_PEN, destination, handlePenToolToggleMenuItem, _menuGroupName);
			_removeDrawingsMenuItem = CustomContextMenuManager.createAndAddMenuItemToDestination(REMOVE_DRAWINGS, destination, handleEraseDrawingsMenuItem, _menuGroupName);
			_changeDrawingMode = CustomContextMenuManager.createAndAddMenuItemToDestination(CHANGE_DRAWING_MODE, destination, handleChangeMode, _menuGroupName);
//			_selectRecordsMenuItem = CustomContextMenuManager.createAndAddMenuItemToDestination(SELECT_RECORDS, destination, handleSelectRecords, _menuGroupName);

			_removeDrawingsMenuItem.enabled = false;
			_changeDrawingMode.enabled = false;
			
			return true;
		}
		
		private static function handleChangeMode(e:ContextMenuEvent):void
		{
			var contextMenu:ContextMenu = (Application.application as Application).contextMenu;
			if (!contextMenu)
				return;
			
			var linkableContainer:ILinkableContainer = getLinkableContainer(e.mouseTarget) as ILinkableContainer;
			if (linkableContainer)
			{
				var penObject:PenTool = linkableContainer.getLinkableChildren().getObject( PEN_OBJECT_NAME ) as PenTool;
				if (penObject)
				{
					if (penObject.drawingMode.value == PenTool.FREE_DRAW_MODE)
					{
						penObject.drawingMode.value = PenTool.POLYGON_DRAW_MODE;
					}
					else
					{
						penObject.drawingMode.value = PenTool.FREE_DRAW_MODE;
					}

					// remove all drawings because it doesn't make sense to allow the user to 
					// select using free draw drawings.
					penObject.coords.value = "";
					
					_removeDrawingsMenuItem.enabled = true;
				}
				CustomCursorManager.showCursor(CustomCursorManager.PEN_CURSOR, CursorManagerPriority.HIGH, -3, -22);
			}
		}
		
		/**
		 * This function is called whenever the context menu is opened.
		 * The function will change the caption displayed depending upon if there is any drawings.
		 * This is also used to get the correct mouse pointer for the context menu.
		 */
		private static function handleContextMenuOpened(e:ContextMenuEvent):void
		{
			var contextMenu:ContextMenu = (Application.application as Application).contextMenu;
			if (!contextMenu)
				return;

			CustomCursorManager.removeCurrentCursor();

			//Reset Context Menu as if no PenMouse Object is there and let following code adjust as necessary.
			_penToolMenuItem.caption = ENABLE_PEN;
			_removeDrawingsMenuItem.enabled = false;

			// If session state is imported need to detect if there are drawings.
			var linkableContainer:ILinkableContainer = getLinkableContainer(e.mouseTarget) as ILinkableContainer;
			if (linkableContainer)
			{
				var penObject:PenTool = linkableContainer.getLinkableChildren().getObject( PEN_OBJECT_NAME ) as PenTool;
				if (penObject)
				{
					if (penObject.editMode)
					{
						_penToolMenuItem.caption = DISABLE_PEN;
					}
					else
					{
						_penToolMenuItem.caption = ENABLE_PEN;
					}
					_removeDrawingsMenuItem.enabled = true;
				}
			}
		}
		
		/**
		 * This function gets called whenever Enable/Disable Pen Tool is clicked in the Context Menu.
		 * This creates a PenMouse object if there isn't one existing already.
		 * All of the necessary event listeners are added and captions are
		 * dealt with appropriately.
		 */
		private static function handlePenToolToggleMenuItem(e:ContextMenuEvent):void
		{
			var linkableContainer:ILinkableContainer = getLinkableContainer(e.mouseTarget);
			
			if (!linkableContainer)
				return;
			
			var penTool:PenTool = linkableContainer.getLinkableChildren().requestObject(PEN_OBJECT_NAME, PenTool, false);
			if(_penToolMenuItem.caption == ENABLE_PEN)
			{
				// enable pen
				
				penTool.editMode = true;
				_penToolMenuItem.caption = DISABLE_PEN;
				_removeDrawingsMenuItem.enabled = true;
				_changeDrawingMode.enabled = true;
				CustomCursorManager.showCursor(CustomCursorManager.PEN_CURSOR, CursorManagerPriority.HIGH, -3, -22);
			}
			else
			{
				// disable pen
				penTool.editMode = false;
				_changeDrawingMode.enabled = false;
				_penToolMenuItem.caption = ENABLE_PEN;
			}
		}
		
		/**
		 * This function is passed a target and checks to see if the target is an ILinkableContainer.
		 * Either a ILinkableContainer or null will be returned.
		 */
		private static function getLinkableContainer(target:*):*
		{
			var targetComponent:* = target;
			
			while (targetComponent)
			{
				if (targetComponent is ILinkableContainer)
					return targetComponent as ILinkableContainer;
				
				targetComponent = targetComponent.parent;
			}
			
			return targetComponent;
		}

		/**
		 * @param target The UIComponent for which to get its PlotLayerContainer.
		 * @return The PlotLayerContainer visualization for the target if it has one. 
		 */		
		private static function getPlotLayerContainer(target:*):PlotLayerContainer
		{
			var linkableContainer:ILinkableContainer = getLinkableContainer(target);
			if (!linkableContainer || !(linkableContainer is SimpleVisTool))
				return null;
			
			var visualization:PlotLayerContainer = (linkableContainer as SimpleVisTool).visualization as PlotLayerContainer;
			
			return visualization;
		}
		/**
		 * This function occurs when Remove All Drawings is pressed.
		 * It removes the PenMouse object and clears all of the event listeners.
		 */
		private static function handleEraseDrawingsMenuItem(e:ContextMenuEvent):void
		{
			var linkableContainer:ILinkableContainer = getLinkableContainer(e.mouseTarget);
			
			if (linkableContainer)
				linkableContainer.getLinkableChildren().removeObject( PEN_OBJECT_NAME );
			_penToolMenuItem.caption = ENABLE_PEN;
			_removeDrawingsMenuItem.enabled = false;
		}
		
		/**
		 * This function is called when the select records context menu item is clicked. 
		 * @param e The event.
		 */		
		private static function handleSelectRecords(e:ContextMenuEvent):void
		{
			var linkableContainer:ILinkableContainer = getLinkableContainer(e.mouseTarget);
			if (!linkableContainer)
				return;
			var visualization:PlotLayerContainer = getPlotLayerContainer(e.mouseTarget) as PlotLayerContainer;
			if (!visualization)
				return;
			
			var penTool:PenTool = linkableContainer.getLinkableChildren().requestObject(PEN_OBJECT_NAME, PenTool, false);
			penTool.selectRecords();
		}		
	}
}