{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Events.ReadEvents (
    registerEventsFromFile
  , registerEventsFromTrace
  , registerEventsFromDBFile
  , registerEventsFromDB
  ) where

import Events.EventDuration
import Events.EventTree
import Events.HECs (HECs (..), histogram)
import Events.SparkTree
import Events.TestEvents
import GUI.ProgressView (ProgressView)
import GUI.Types (DBMetaData, EParsers, DBState(..))
import qualified GUI.ProgressView as ProgressView

import GHC.RTS.Events
import GHC.RTS.Events.Incremental (getEventParsers)

import GHC.RTS.Events.Analysis
import GHC.RTS.Events.Analysis.Capability
import GHC.RTS.Events.Analysis.SparkThread

import qualified Control.DeepSeq as DeepSeq
import Control.Exception
import Control.Monad
import Data.Array
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BL
import Data.Either
import Data.Function
import qualified Data.IntMap as IM
import qualified Data.List as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Time.Clock
import System.FilePath
import Text.Printf

import GHC.Stack

import Database.SQLite.Simple (FromRow (..), ToRow (..), Connection, Statement (..), Query (..))
import qualified Database.SQLite.Simple as DB

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

rawEventsToHECs :: [Event] -> Timestamp
                -> [(Double, (DurationTree, EventTree, SparkTree))]
rawEventsToHECs evs endTime
  = map (\cap -> toTree $ L.find ((Just cap ==) . evCap . head) heclists)
      [0 .. maximum (0 : map (fromMaybe 0 . evCap) evs)]
  where
    heclists =
      L.groupBy ((==) `on` evCap) $ L.sortBy (compare `on` evCap) evs

    toTree Nothing    = (0, (DurationTreeEmpty,
                             EventTree 0 0 (EventTreeLeaf []),
                             emptySparkTree))
    toTree (Just evs) =
      (maxSparkPool,
       (mkDurationTree (eventsToDurations nondiscrete) endTime,
        mkEventTree discrete endTime,
        mkSparkTree sparkD endTime))
       where (discrete, nondiscrete) = L.partition isDiscreteEvent evs
             (maxSparkPool, sparkD)  = eventsToSparkDurations nondiscrete

-------------------------------------------------------------------------------

registerEventsFromFile :: String -> ProgressView
                       -> IO (HECs, String, Int, Double)
registerEventsFromFile filename = registerEvents (Left filename)

registerEventsFromTrace :: String -> ProgressView
                        -> IO (HECs, String, Int, Double)
registerEventsFromTrace traceName = registerEvents (Right traceName)

registerEventsFromDBFile :: String
                       -> IO (HECs, DBState, String, Int, Double)
registerEventsFromDBFile filename = registerEventsDBFile filename

registerEventsFromDB :: DBState
                     -> (Double, Double) -> Double -> Double
                     -> IO (HECs, DBState, Int, Double)
registerEventsFromDB dbstate = registerEventsDB dbstate

registerEvents :: Either FilePath String
               -> ProgressView
               -> IO (HECs, String, Int, Double)

registerEvents from progress = do

  let msg = case from of
              Left filename -> filename
              Right test    -> test

  ProgressView.setTitle progress ("Loading " ++ takeFileName msg)

  buildEventLog progress from

registerEventsDBFile :: FilePath
                 -> IO (HECs, DBState, String, Int, Double)
registerEventsDBFile from = do
  buildEventLogDBFile from

registerEventsDB :: DBState
                 -> (Double, Double) -> Double -> Double
                 -> IO (HECs, DBState, Int, Double)
registerEventsDB from (lower, upper) pagesize val = do
  buildEventLogDB from (lower, upper) pagesize val

-- | Integer division, rounding up.
divUp :: Timestamp -> Timestamp -> Timestamp
divUp n k = (n + k - 1) `div` k

-------------------------------------------------------------------------------
-- SQLite things
--
instance FromRow EventType where
  fromRow = EventType <$> DB.field
                      <*> DB.field
                      <*> DB.field

readHeaderFromDB :: Connection -> IO Header
readHeaderFromDB conn =
    Header <$> DB.query_ conn "select num, desc, size from etypes"

readMetaDataFromDB :: Connection -> IO DBMetaData
readMetaDataFromDB conn = do
    (n_events, _min_ts :: Timestamp, max_ts, n_hec) <- head <$> DB.query_  conn "select COUNT(id), MIN(timestamp), MAX(timestamp), MAX(cap) from evts"
    return (n_events, 0, max_ts, n_hec + 1)

-- Read first 10 events for every cap
readEventLogFromDB :: Connection -> EParsers -> Maybe Int -> (Timestamp, Timestamp) -> IO [[Event]]
readEventLogFromDB conn parsers Nothing (_, _) = do
  putStrLn $ "read db begin"
  t1 <- getCurrentTime
  bytes <- DB.query_ conn "select timestamp, etype, einfo from evts where cap is NULL ORDER by timestamp ASC"
  rs <- forM bytes $ \(ts, etype, ebytes) ->
          return $ Event ts (runGet (parsers ! etype) ebytes) Nothing
  t2 <- getCurrentTime
  putStrLn $ "read db end: " ++ show (diffUTCTime t2 t1)
  return [rs]
readEventLogFromDB conn parsers (Just ncap) (start_ts, end_ts) = do
  putStrLn $ "read db begin: (" ++ show start_ts ++ ", " ++ show end_ts ++ ")"
  t1 <- getCurrentTime
  print $ "ncap = " ++ show ncap
  rs <- forM [0..ncap-1] $ \cap -> do
    bytes <- DB.query conn "select timestamp, etype, einfo from evts where cap = ? and timestamp >= ? and timestamp <= ? ORDER by timestamp ASC" (cap, start_ts, end_ts)
    forM bytes $ \(ts, etype, ebytes) ->
      return $ Event ts (runGet (parsers ! etype) ebytes) (Just cap)
  t2 <- getCurrentTime
  putStrLn $ "read db end: " ++ show (diffUTCTime t2 t1)
  return rs

-------------------------------------------------------------------------------
-- Runs in a background thread
--
buildEventLogDBFile :: FilePath
                -> IO (HECs, DBState, String, Int, Double)
buildEventLogDBFile filename = do
  conn <- DB.open filename
  DB.execute_ conn "PRAGMA journal_mode = MEMORY"
  DB.execute_ conn "PRAGMA synchronous = OFF"
  meta@(_, min_ts, max_ts, n_hec) <- readMetaDataFromDB conn
  parsers <- getEventParsers <$> readHeaderFromDB conn
  let dbstate = DBState meta conn parsers
  evts <- concat <$> readEventLogFromDB conn parsers Nothing (min_ts, max_ts)
  (hecs, nevents, timespan) <- buildTheView dbstate evts
  return (hecs, dbstate, filename, nevents, timespan)

locationTsPoint :: (Double, Double)
                -> (Timestamp, Timestamp)
                -> Double
                -> Timestamp
locationTsPoint (lower, upper) (min_ts, max_ts) val =
  min_ts + round ((val - lower) * (fromIntegral (max_ts - min_ts)) / (upper - lower))

buildEventLogDB :: DBState
                -> (Double, Double) -> Double -> Double
                -> IO (HECs, DBState, Int, Double)
buildEventLogDB dbstate@DBState{meta = (_, min_ts, max_ts, n_hec), conn = conn, parsers = parsers} (lower, upper) pagesize val = do
  let begin_ts = locationTsPoint (lower, upper) (min_ts, max_ts) val
      end_ts   = locationTsPoint (lower, upper) (min_ts, max_ts) (val + pagesize)
  putStrLn $ show (min_ts, max_ts) ++ "  " ++ show (lower, upper) ++ "   " ++ show (pagesize, val) ++ "  " ++ show (begin_ts, end_ts)
  evts      <- concat <$> readEventLogFromDB conn parsers (Just n_hec) (begin_ts, end_ts)
  evtsNoCap <- concat <$> readEventLogFromDB conn parsers Nothing      (begin_ts, end_ts)
  (hecs, nevents, timespan) <- buildTheView dbstate (evtsNoCap ++ evts)
  return (hecs, dbstate, nevents, timespan)

buildTheView :: DBState
             -> [Event]
             -> IO (HECs, Int, Double)
buildTheView dbstate@DBState{meta = (n_events, _, max_ts, n_hec), conn = conn} evs = do
    zipWithM_ treeProgress [0..] trees

    -- TODO: fully evaluate HECs before returning because otherwise the last
    -- bit of work gets done after the progress window has been closed.
    return (hecs, n_events, fromIntegral lastTx / 1000000)
  where

      eBy1000 ev = ev{evTime = evTime ev `divUp` 1000}
      eventsBy = map eBy1000 evs

      -- 1, to avoid graph scale 0 and division by 0 later on
      lastTx = max 1 (max_ts `divUp` 1000)

      -- Add caps to perf events, using the OS thread numbers
      -- obtained from task validation data.
      -- Only the perf events with a cap are displayed in the timeline.
      -- TODO: it may make sense to move this code to ghc-events
      -- and run after to-eventlog and ghc-events merge, but it requires
      -- one more step in the 'perf to TS' workflow and is a bit slower
      -- (yet another event sorting and loading eventlog chunks
      -- into the CPU cache).
      steps :: HasCallStack => [Event] -> [(Map KernelThreadId Int, Event)]
      steps evs =
        zip (map fst $ rights $ validates capabilityTaskOSMachine evs) evs

      addC :: HasCallStack => (Map KernelThreadId Int, Event) -> Event
      addC (state, ev@Event{evSpec=PerfTracepoint{tid}}) =
        case M.lookup tid state of
          Nothing -> ev  -- unknown task's OS thread
          evCap  -> ev {evCap}
      addC (state, ev@Event{evSpec=PerfCounter{tid}}) =
        case M.lookup tid state of
          Nothing -> ev  -- unknown task's OS thread
          evCap  -> ev {evCap}
      addC (_, ev) = ev

      addCaps evs = map addC (steps evs)

      -- sort the events by time, add extra caps and put them in an array
      sorted = addCaps $ sortEvents eventsBy
      maxTrees = rawEventsToHECs sorted lastTx
      maxSparkPool = maximum (0 : map fst maxTrees)
      trees = map snd maxTrees

      -- put events in an array
      n_events  = length sorted
      event_arr = listArray (0, n_events-1) sorted
      hec_count = length trees

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

      sparkProfile :: HasCallStack => Process
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

      sparkSummary :: HasCallStack => Map ThreadId (Int, Timestamp, Timestamp)
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

      allHisto :: HasCallStack => [(Timestamp, Int, Timestamp)]
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

      treeProgress :: HasCallStack => Int -> (DurationTree, EventTree, SparkTree) -> IO ()
      treeProgress hec (tree1, tree2, tree3) = do
         evaluate tree1
         evaluate (eventTreeMaxDepth tree2)
         evaluate (sparkTreeMaxDepth tree3)
         when (hec_count == 1 || hec == 1)  -- eval only with 2nd HEC
           (return $! DeepSeq.rnf durHistogram)

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
  build name evs = do
    let
      eBy1000 ev = ev{evTime = evTime ev `divUp` 1000}
      eventsBy = map eBy1000 (events (dat evs))
      eventBlockEnd e | EventBlock{ end_time=t } <- evSpec e = t
      eventBlockEnd e = evTime e

      -- 1, to avoid graph scale 0 and division by 0 later on
      lastTx = maximum (1 : map eventBlockEnd eventsBy)

      -- Add caps to perf events, using the OS thread numbers
      -- obtained from task validation data.
      -- Only the perf events with a cap are displayed in the timeline.
      -- TODO: it may make sense to move this code to ghc-events
      -- and run after to-eventlog and ghc-events merge, but it requires
      -- one more step in the 'perf to TS' workflow and is a bit slower
      -- (yet another event sorting and loading eventlog chunks
      -- into the CPU cache).
      steps :: [Event] -> [(Map KernelThreadId Int, Event)]
      steps evs =
        zip (map fst $ rights $ validates capabilityTaskOSMachine evs) evs
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
      addCaps evs = map addC (steps evs)

      -- sort the events by time, add extra caps and put them in an array
      sorted = addCaps $ sortEvents eventsBy
      maxTrees = rawEventsToHECs sorted lastTx
      maxSparkPool = maximum (0 : map fst maxTrees)
      trees = map snd maxTrees

      -- put events in an array
      n_events  = length sorted
      event_arr = listArray (0, n_events-1) sorted
      hec_count = length trees

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

    zipWithM_ treeProgress [0..] trees
    ProgressView.setProgress progress hec_count hec_count

    -- TODO: fully evaluate HECs before returning because otherwise the last
    -- bit of work gets done after the progress window has been closed.

    return (hecs, name, n_events, fromIntegral lastTx / 1000000)
