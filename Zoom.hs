{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS -fno-warn-unused-matches #-}
module Zoom (
     zoomIn, zoomOut, zoomToFit
  ) where

import State
import EventlogViewerCommon

-- Imports for GTK/Glade
import Graphics.UI.Gtk

import Data.IORef

-------------------------------------------------------------------------------
-- Zoom in works by expanding the current view such that the 
-- left hand edge of the original view remains at the same
-- position and the zoom in factor is 2.
-- For example, zoom into the time range 1.0 3.0
-- produces a new view with the time range 1.0 2.0

zoomIn :: IORef Double -> HScrollbar ->
          Statusbar -> ContextId -> DrawingArea
          -> IO ()
zoomIn scale profileHScrollbar statusbar ctx canvas
  = do scaleValue <- readIORef scale -- Halve the scale value
       let newScaleValue = scaleValue/2
       writeIORef scale newScaleValue
       hadj <- rangeGetAdjustment profileHScrollbar -- Get horizontal scrollbar
       hadj_pagesize <- adjustmentGetPageSize hadj -- Get size of bar
       let newPageSize = hadj_pagesize / 2
       adjustmentSetPageSize hadj newPageSize
       rangeSetIncrements profileHScrollbar 
        (0.1 * newPageSize) (0.9 * newPageSize)
       statusbarPush statusbar ctx ("Scale " ++ show newScaleValue)
       widgetQueueDraw canvas

-------------------------------------------------------------------------------
-- Zoom out works by contracting the current view such that the
-- left hand edge of the original view remains at the same
-- position and the zoom out factor is 2.
-- For example, zoom out of the time range 1.0 2.0
-- produces a new view with the time range 1.0 3.0

zoomOut :: IORef Double -> HScrollbar -> 
           Statusbar -> ContextId -> DrawingArea
           -> IO ()
zoomOut scale profileHScrollbar statusbar ctx canvas
  = do scaleValue <- readIORef scale
       let newScaleValue = scaleValue*2
       writeIORef scale newScaleValue
       hadj <- rangeGetAdjustment profileHScrollbar
       hadj_pagesize <- adjustmentGetPageSize hadj
       let newPageSize = hadj_pagesize * 2
       adjustmentSetPageSize hadj newPageSize
       rangeSetIncrements profileHScrollbar     
         (0.1 * newPageSize) (0.9 * newPageSize)   
       statusbarPush statusbar ctx ("Scale " ++ show newScaleValue)
       widgetQueueDraw canvas        
       
-------------------------------------------------------------------------------

zoomToFit :: ViewerState -> IO ()
zoomToFit ViewerState{..} = do
  mb_hecs <- readIORef hecsIORef
  case mb_hecs of
    Nothing   -> writeIORef scaleIORef (-1.0)
    Just hecs -> do
       let lastTx = findLastTxValue hecs
       (w, _) <- widgetGetSize profileDrawingArea
       let newScale = fromIntegral lastTx / 
                      fromIntegral (w - 2*ox - 20 - barHeight)
       writeIORef scaleIORef newScale
       -- Configure the horizontal scrollbar units to correspond to
       -- Timespec values
       hadj <- rangeGetAdjustment profileHScrollbar
       adjustmentSetUpper hadj (fromIntegral lastTx)
       adjustmentSetPageSize hadj (fromIntegral lastTx)
       rangeSetIncrements profileHScrollbar 0 0
