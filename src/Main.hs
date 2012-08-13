-- |
-- Module      : Main
-- Copyright   : (c) 2012 Brendan Hay <brendan@soundcloud.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan@soundcloud.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Main (
    -- * Main Entry Point
      main
    ) where

import Control.Concurrent
import Control.Exception.Base (finally)
import Control.Monad          (liftM)
import System.IO.Unsafe       (unsafePerformIO)
import GameKeeper.API
import GameKeeper.Logger
import GameKeeper.Metric
import GameKeeper.Nagios
import GameKeeper.Options
import System.Exit            (ExitCode(..), exitWith)
import Text.Printf            (printf)

--
-- API
--

main :: IO ()
main = parseOptions >>= run
  where
    run (Left s)  = putStrLn s >> exitWith (ExitFailure 1)
    run (Right o) = logDebug ("Mode: " ++ show o) >> mode o

--
-- Modes
--

mode :: Options -> IO ()
mode Measure{..} = do
    sink <- open optSink
    forkAll [ showOverview optUri >>= push sink
            , listConnections optUri >>= idleConnections optDays >>= push sink
            , listChannels optUri >>= push sink
            , listExchanges optUri >>= mapM_ (push sink)
            , do qs <- listQueues optUri
                 push sink $ idleQueues qs
                 mapM_ (push sink) qs
            , listBindings optUri >>= push sink
            ]
    wait
    close sink

mode PruneConnections{..} = do
    cs <- liftM idle (listConnections optUri >>= idleConnections optDays)
    putStrLn $ "Idle Connections Found: " ++ show (length cs)
    mapM_ (deleteConnection optUri) cs

mode PruneQueues{..} = do
    qs <- listQueues optUri
    mapM_ (deleteQueue optUri) . idle $ unusedQueues qs

mode CheckNode{..} = exec $ Plugin "NODE"
    [ check
      { name     = "BACKLOG"
      , value    = liftM (total . count) (showOverview optUri)
      , health   = optMessages
      , ok       = printf "%.0f messages ready"
      , critical = printf "%.0f/.0%f messages ready"
      , warning  = printf "%.0f/.0%f messages ready"
      }
    , check
      { name     = "MEMORY"
      , value    = liftM used (showNode optUri optName)
      , health   = optMemory
      , ok       = printf "%.2fGB mem used"
      , critical = printf "%.2f/%.2fGB mem used"
      , warning  = printf "%.2/%.2fGB mem used"
      }
    ]

mode CheckQueue{..} = exec $ Plugin "QUEUE"
    [ check
      { name     = "BACKLOG"
      , value    = liftM messages queue
      , health   = optMessages
      , ok       = printf "%.0f messages ready"
      , critical = printf "%.0f/.0%f messages ready"
      , warning  = printf "%.0f/.0%f messages ready"
      }
    , check
      { name     = "MEMORY"
      , value    = liftM memory queue
      , health   = optMemory
      , ok       = printf "%.2fMB mem used"
      , critical = printf "%.2f/%.2fMB mem used"
      , warning  = printf "%.2/%.2fMB mem used"
      }
    ]
  where
    queue = showQueue optUri optName

mode _ = logError err >> error err
  where
    err = "Unsupported mode"

--
-- Forking
--

children :: MVar [MVar ()]
children = unsafePerformIO (newMVar [])

forkAll :: [IO ()] -> IO ()
forkAll = mapM_ fork

fork :: IO () -> IO ThreadId
fork io = do
    mvar    <- newEmptyMVar
    threads <- takeMVar children
    putMVar children (mvar:threads)
    forkIO (io `finally` putMVar mvar ())

wait :: IO ()
wait = do
    cs <- takeMVar children
    case cs of
        []   -> return ()
        m:ms -> do
            putMVar children ms
            takeMVar m
            wait
