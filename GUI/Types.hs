module GUI.Types (
    ViewParameters(..),
    Trace(..),
    Timestamp,
    Interval,

    -- * DB
    DBMetaData,
    EParsers,
    DBState (..)
  ) where

import GHC.RTS.Events

import Data.Array (Array)
import Data.Binary.Get (Get)
import Database.SQLite.Simple (Connection)

-----------------------------------------------------------------------------

data Trace
  = TraceHEC      Int
  | TraceInstantHEC Int
  | TraceCreationHEC Int
  | TraceConversionHEC Int
  | TracePoolHEC  Int
  | TraceHistogram
  | TraceGroup    String
  | TraceActivity
  -- more later ...
  --  | TraceThread   ThreadId
  deriving Eq

type Interval = (Timestamp, Timestamp)

-- the parameters for a timeline render; used to figure out whether
-- we're drawing the same thing twice.
data ViewParameters = ViewParameters {
    width, height :: Int,
    viewTraces    :: [Trace],
    hadjValue     :: Double,
    scaleValue    :: Double,
    maxSpkValue   :: Double,
    detail        :: Int,
    bwMode, labelsMode :: Bool,
    histogramHeight :: Int,
    minterval :: Maybe Interval,
    xScaleAreaHeight :: Int
  }
  deriving Eq

-------------------------------------------------------------------------------
-- SQLite

type DBMetaData = ( Int         -- ^ n_events
                  , Timestamp   -- ^ min_timestamp / 1000
                  , Timestamp   -- ^ max_timestamp / 1000
                  , Int         -- ^ n_hec
                  )

type EParsers = Array Int (Get EventInfo)

data DBState = DBState {
    meta     :: DBMetaData,
    conn     :: Connection,
    parsers  :: EParsers
  }
