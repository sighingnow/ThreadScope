module Events.ReadEvents (
    registerEventsFromFile, registerEventsFromTrace
  ) where

import Events.EventDuration
import Events.EventTree
import Events.HECs (HECs (..), histogram)
import Events.SparkTree
import Events.TestEvents
import GUI.ProgressView (ProgressView)
import qualified GUI.ProgressView as ProgressView

import GHC.RTS.Events

import GHC.RTS.Events.Analysis
import GHC.RTS.Events.Analysis.Capability
import GHC.RTS.Events.Analysis.SparkThread

import qualified Control.DeepSeq as DeepSeq
import Control.Exception
import Control.Monad
import Data.Array
import Data.Either
import Data.Function
import qualified Data.IntMap as IM
import qualified Data.List as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import System.FilePath
import Text.Printf

import Control.Monad.ST
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import qualified Data.Vector.Algorithms.Tim as V
import qualified Data.Array.ST as STArr
import qualified Data.Array.MArray as MArr

-------------------------------------------------------------------------------
-- import qualified GHC.RTS.Events as GHCEvents
--
-- The GHC.RTS.Events library returns the profile information
-- in a data-streucture which contains a list data structure
-- representing the events i.e. [GHCEvents.Event]
-- ThreadScope transforms this list into an alternative representation
-- which (for each HEC) records event *durations* which are ordered in time.
-- The durations represent the run-lengths for thread execution and
-- run-lengths for garbage colleciton. This data-structure is called
-- EventDuration.
-- ThreadScope then transformations this data-structure into another
-- data-structure which gives a binary-tree view of the event information
-- by performing a binary split on the time domain i.e. the EventTree
-- data structure.

-- GHCEvents.Event => [EventDuration] => EventTree

-------------------------------------------------------------------------------

rawEventsToHECs :: Vector Event -> Timestamp
                -> Vector (Double, (DurationTree, EventTree, SparkTree))
rawEventsToHECs evs endTime
  = V.map (\cap -> toTree $ L.find ((Just cap ==) . evCap . V.head) heclists)
      (V.iterateN (max 0 (V.maximum (V.map (fromMaybe 0 . evCap) evs))) (+1) 0)
  where
    heclists =
      groupBy' ((==) `on` evCap) $ runST $ do
        mevs <- MV.new (V.length evs)
        V.copy mevs evs
        V.sortBy (compare `on` evCap) mevs
        V.freeze mevs

    toTree :: Maybe (Vector Event) -> (Double, (DurationTree, EventTree, SparkTree))
    toTree Nothing    = (0, (DurationTreeEmpty,
                             EventTree 0 0 (EventTreeLeaf []),
                             emptySparkTree))
    toTree (Just evs) =
      (maxSparkPool,
       (mkDurationTree (eventsToDurations nondiscrete) endTime,
        mkEventTree discrete endTime,
        mkSparkTree sparkD endTime))
       where (discrete, nondiscrete) = let (xs, ys) = V.partition isDiscreteEvent evs
                                        in (V.toList xs, V.toList ys)
             (maxSparkPool, sparkD)  = eventsToSparkDurations nondiscrete

    groupBy' :: (a -> a -> Bool) -> Vector a -> [Vector a]
    groupBy' cmp xs = if V.null xs
                     then []
                     else let (r1, r2) = V.span (V.head xs `cmp`) xs
                           in r1 : groupBy' cmp r2

-------------------------------------------------------------------------------

registerEventsFromFile :: String -> ProgressView
                       -> IO (HECs, String, Int, Double)
registerEventsFromFile filename = registerEvents (Left filename)

registerEventsFromTrace :: String -> ProgressView
                        -> IO (HECs, String, Int, Double)
registerEventsFromTrace traceName = registerEvents (Right traceName)

registerEvents :: Either FilePath String
               -> ProgressView
               -> IO (HECs, String, Int, Double)

registerEvents from progress = do

  let msg = case from of
              Left filename -> filename
              Right test    -> test

  ProgressView.setTitle progress ("Loading " ++ takeFileName msg)

  buildEventLog progress from

-------------------------------------------------------------------------------
-- Runs in a background thread
--
buildEventLog :: ProgressView -> Either FilePath String
              -> IO (HECs, String, Int, Double)
buildEventLog progress from =
  case from of
    Right test     -> build test (testTrace test)
    Left filename  -> do
      stopPulse <- ProgressView.startPulse progress
      fmt <- readEventLogFromFile filename
      stopPulse
      case fmt of
        Left  err -> fail err --FIXME: report error properly
        Right evs -> build filename evs

 where
  -- | Integer division, rounding up.
  divUp :: Timestamp -> Timestamp -> Timestamp
  divUp n k = (n + k - 1) `div` k

  build name evs = do
    let
      eBy1000 ev = ev{evTime = evTime ev `divUp` 1000}
      eventsBy = V.map eBy1000 (events (dat evs))
      eventBlockEnd e | EventBlock{ end_time=t } <- evSpec e = t
      eventBlockEnd e = evTime e

      -- 1, to avoid graph scale 0 and division by 0 later on
      lastTx = max 1 (V.maximum (V.map eventBlockEnd eventsBy))

      -- Add caps to perf events, using the OS thread numbers
      -- obtained from task validation data.
      -- Only the perf events with a cap are displayed in the timeline.
      -- TODO: it may make sense to move this code to ghc-events
      -- and run after to-eventlog and ghc-events merge, but it requires
      -- one more step in the 'perf to TS' workflow and is a bit slower
      -- (yet another event sorting and loading eventlog chunks
      -- into the CPU cache).
      maybeRightFirst e = case e of
                            Left _ -> Nothing
                            Right v -> Just (fst v)
      steps :: Vector Event -> Vector (Map KernelThreadId Int, Event)
      steps evs =
        -- zip (map fst $ rights $ validates capabilityTaskOSMachine evs) evs
        V.zip (V.mapMaybe maybeRightFirst $ validates' capabilityTaskOSMachine evs) evs
      addC :: (Map KernelThreadId Int, Event) -> Event
      addC (state, ev@Event{evSpec=PerfTracepoint{tid}}) =
        case M.lookup tid state of
          Nothing -> ev  -- unknown task's OS thread
          evCap  -> ev {evCap}
      addC (state, ev@Event{evSpec=PerfCounter{tid}}) =
        case M.lookup tid state of
          Nothing -> ev  -- unknown task's OS thread
          evCap  -> ev {evCap}
      addC (_, ev) = ev
      addCaps evs = V.map addC (steps evs)

      -- sort the events by time, add extra caps and put them in an array
      sorted = addCaps $ sortEvents' eventsBy
      maxTrees = rawEventsToHECs sorted lastTx
      maxSparkPool = max 0 (V.maximum (V.map fst maxTrees))
      trees = V.map snd maxTrees

      -- put events in an array
      n_events  = V.length sorted
      -- event_arr = listArray (0, n_events-1) sorted
      event_arr = STArr.runSTArray $ do
        arr <- MArr.newArray_ (0, n_events - 1)
        V.imapM_ (\i x -> MArr.writeArray arr i x) sorted
        return arr

      hec_count = V.length trees

      -- Pre-calculate the data for the sparks histogram.
      intDoub :: Integral a => a -> Double
      intDoub = fromIntegral
      -- Discretizes the data using log.
      -- Log base 2 seems to result in 7--15 bars, which is OK visually.
      -- Better would be 10--15 bars, but we want the base to be a small
      -- integer, for readable scales, and we can't go below 2.
      ilog :: Timestamp -> Int
      ilog 0 = 0
      ilog x = floor $ logBase 2 (intDoub x)
      times :: (Int, Timestamp, Timestamp)
            -> Maybe (Timestamp, Int, Timestamp)
      times (_, timeStarted, timeElapsed) =
        Just (timeStarted, ilog timeElapsed, timeElapsed)

      sparkProfile :: Process
                        ((Map ThreadId (Profile SparkThreadState),
                          (Map Int ThreadId, Set ThreadId)),
                         Event)
                        (ThreadId, (SparkThreadState, Timestamp, Timestamp))
      sparkProfile  = profileRouted
                        (refineM evSpec sparkThreadMachine)
                        capabilitySparkThreadMachine
                        capabilitySparkThreadIndexer
                        evTime
                        sorted

      sparkSummary :: Map ThreadId (Int, Timestamp, Timestamp)
                   -> [(ThreadId, (SparkThreadState, Timestamp, Timestamp))]
                   -> [Maybe (Timestamp, Int, Timestamp)]
      sparkSummary m [] = map times $ M.elems m
      sparkSummary m ((threadId, (state, timeStarted', timeElapsed')):xs) =
        case state of
          SparkThreadRunning sparkId' -> case M.lookup threadId m of
            Just el@(sparkId, timeStarted, timeElapsed) ->
              if sparkId == sparkId'
              then let value = (sparkId, timeStarted, timeElapsed + timeElapsed')
                   in sparkSummary (M.insert threadId value m) xs
              else times el : newSummary sparkId' xs
            Nothing -> newSummary sparkId' xs
          _ -> sparkSummary m xs
       where
        newSummary sparkId = let value = (sparkId, timeStarted', timeElapsed')
                             in sparkSummary (M.insert threadId value m)

      allHisto :: [(Timestamp, Int, Timestamp)]
      allHisto = catMaybes . sparkSummary M.empty . toList $ sparkProfile

      -- Sparks of zero lenght are already well visualized in other graphs:
      durHistogram = filter (\ (_, logdur, _) -> logdur > 0) allHisto
      -- Precompute some extremums of the maximal interval, needed for scales.
      durs = [(logdur, dur) | (_start, logdur, dur) <- durHistogram]
      (logDurs, sumDurs) = L.unzip (histogram durs)
      minXHistogram = minimum (maxBound : logDurs)
      maxXHistogram = maximum (minBound : logDurs)
      maxY          = maximum (minBound : sumDurs)
      -- round up to multiples of 10ms
      maxYHistogram = 10000 * ceiling (fromIntegral maxY / 10000)

      getPerfNames nmap ev =
        case evSpec ev of
          PerfName{perfNum, name} ->
            IM.insert (fromIntegral perfNum) name nmap
          _ -> nmap
      perfNames = L.foldl' getPerfNames IM.empty eventsBy

      hecs = HECs {
               hecCount         = hec_count,
               hecTrees         = trees,
               hecEventArray    = event_arr,
               hecLastEventTime = lastTx,
               maxSparkPool,
               minXHistogram,
               maxXHistogram,
               maxYHistogram,
               durHistogram,
               perfNames
            }

      treeProgress :: Int -> (DurationTree, EventTree, SparkTree) -> IO ()
      treeProgress hec (tree1, tree2, tree3) = do
         ProgressView.setText progress $
                  printf "Building HEC %d/%d" (hec+1) hec_count
         ProgressView.setProgress progress hec_count hec
         evaluate tree1
         evaluate (eventTreeMaxDepth tree2)
         evaluate (sparkTreeMaxDepth tree3)
         when (hec_count == 1 || hec == 1)  -- eval only with 2nd HEC
           (return $! DeepSeq.rnf durHistogram)

    V.zipWithM_ treeProgress (V.iterateN (V.length trees) (+1) 0) trees
    ProgressView.setProgress progress hec_count hec_count

    -- TODO: fully evaluate HECs before returning because otherwise the last
    -- bit of work gets done after the progress window has been closed.

    return (hecs, name, n_events, fromIntegral lastTx / 1000000)
