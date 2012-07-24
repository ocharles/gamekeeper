-- |
-- Module      : GameKeeper.API.Queue
-- Copyright   : (c) 2012 Brendan Hay <brendan@soundcloud.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan@soundcloud.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module GameKeeper.API.Queue (
    Queue
  , list
  ) where

import Control.Applicative ((<$>), (<*>), empty)
import Control.Monad       (liftM)
import Data.Aeson          (decode')
import Data.Aeson.Types
import Data.Vector         (Vector, toList)
import Network.Metric
import GameKeeper.Http

import GameKeeper.Metric as M

import qualified Data.ByteString.Char8 as BS

data Queue = Queue
    { name      :: BS.ByteString
    , messages  :: Integer
    , consumers :: Integer
    , memory    :: Double
    } deriving (Show)

instance FromJSON Queue where
    parseJSON (Object o) = Queue
        <$> o .: "name"
        <*> o .: "messages"
        <*> o .: "consumers"
        <*> liftM megabytes (o .: "memory")
    parseJSON _ = empty

instance Measurable Queue where
    measure Queue{..} =
        [ gauge group name "messages" (fromIntegral messages)
        , gauge group name "consumers" (fromIntegral consumers)
        , gauge group name "memory" memory
        ]

--
-- API
--

list :: Uri -> IO [Queue]
list uri = do
    body <- getBody uri { uriPath = "api/queues", uriQuery = qs }
    return $ case (decode' body :: Maybe (Vector Queue)) of
        Just v  -> toList v
        Nothing -> []
  where
    qs = "?columns=name,messages,consumers,memory"

--
-- Private
--

megabytes :: Double -> Double
megabytes = (!! 2) . iterate (/ 1024)