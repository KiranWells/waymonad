{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
module Waymonad
    ( get
    , modify

    , WayStateRef
    , WayState
    , runWayState
    , runWayState'

    , LayoutCacheRef
    , LayoutCache
    , runLayoutCache
    , runLayoutCache'

    , viewBelow
    , floatBelow

    , KeyBinding
    , BindingMap
    , LogFun

    , WayBindingState (..)
    , runWayBinding

    , Way
    , getState
    , getSeat
    , runWay
    , makeCallback
    , setCallback
    , withSeat
    , getViewSet

    , WayLoggers (..)
    , Logger (..)
    , getLoggers

    , EventClass
    , SomeEvent
    , getEvent
    , sendEvent
    )
where

import System.IO.Unsafe (unsafeInterleaveIO)

import Control.Applicative ((<|>))
import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT(..), MonadReader(..), local)
import Control.Monad.Trans.Class (MonadTrans (..))
import Data.IORef (IORef, modifyIORef, readIORef)
import Data.IntMap (IntMap)
import Data.Map (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Typeable (Typeable, typeOf, cast)
import Data.Word (Word32)

import Graphics.Wayland.WlRoots.Box (Point (..), WlrBox)

import Input.Seat (Seat)
import View (View, getViewEventSurface)
import Waymonad.Extensible
import Waymonad.Types


import qualified ViewSet as VS
import qualified Data.IntMap as IM
import qualified Data.Set as S



get :: (MonadReader (IORef a) m, MonadIO m) => m a
get = liftIO . readIORef =<< ask

modify :: (MonadReader (IORef a) m, MonadIO m) => (a -> a) -> m ()
modify fun = do
    ref <- ask
    liftIO $ modifyIORef ref fun

runWayState :: MonadIO m =>  WayState a b -> WayStateRef a -> m b
runWayState (WayState m) ref = liftIO $ runReaderT m ref

runWayState' :: MonadIO m => WayStateRef a -> WayState a b -> m b
runWayState' ref act = runWayState act ref

runLayoutCache :: MonadIO m => LayoutCache a -> LayoutCacheRef -> m a
runLayoutCache (LayoutCache m) ref = liftIO $ runReaderT m ref

runLayoutCache' :: MonadIO m => LayoutCacheRef -> LayoutCache a -> m a
runLayoutCache' ref act = runLayoutCache act ref

floatBelow
    :: Point
    -> Way a (Maybe View)
floatBelow (Point x y) = do
    views <- liftIO . fmap S.toList . readIORef . wayFloating =<< getState
    candidates <- liftIO $ forM views $
        \view -> unsafeInterleaveIO $ (fmap . fmap) (const view) $
            getViewEventSurface view (fromIntegral x) (fromIntegral y)

    pure $ foldl (<|>) Nothing candidates

viewBelow
    :: Point
    -> Int
    -> Way a (Maybe (View, Int, Int))
viewBelow point ws = do
    fullCache <- liftIO . readIORef . wayBindingCache =<< getState
    case IM.lookup ws fullCache of
        Nothing -> pure Nothing
        Just x -> liftIO $ VS.viewBelow point x


getEvent :: EventClass e => SomeEvent -> Maybe (e)
getEvent (SomeEvent e) = cast e

sendEvent :: EventClass e => e -> Way a ()
sendEvent e = flip wayEventHook (SomeEvent e) =<< getState

getLoggers :: Way a WayLoggers
getLoggers = Way $ lift getLoggers'
    where   getLoggers' :: WayBinding a WayLoggers
            getLoggers' = WayBinding $ lift ask

getState :: Way a (WayBindingState a)
getState = Way $ lift ask

getSeat :: Way a (Maybe Seat)
getSeat = do
    current <- ask
    case current of
        Just _ -> pure current
        Nothing -> do
            seats <- liftIO . readIORef . wayBindingSeats =<< getState
            pure $ case seats of
                [x] -> Just x
                _ -> Nothing

getViewSet :: Way a (VS.ViewSet a)
getViewSet = liftIO . readIORef . wayBindingState =<< getState

runWayLogging :: MonadIO m => WayLoggers -> WayLogging a -> m a
runWayLogging val (WayLogging act) = liftIO $ runReaderT act val

runWayBinding :: MonadIO m => WayLoggers -> WayBindingState a -> WayBinding a b -> m b
runWayBinding logger val (WayBinding act) =
    liftIO $ runWayLogging logger $ runReaderT act val


runWay
    :: MonadIO m
    => Maybe Seat
    -> WayBindingState a
    -> WayLoggers
    -> Way a b
    -> m b
runWay seat state logger (Way m) =
    liftIO $ runWayBinding logger state $ runReaderT m seat

makeCallback :: (c -> Way a b) -> Way a (c -> IO b)
makeCallback act = do
    seat <- getSeat
    state <- getState
    loggers <- getLoggers
    pure (\arg -> runWay seat state loggers (act arg))

setCallback :: (c -> Way a b) -> ((c -> IO b) -> IO d) -> Way a d
setCallback act fun = do
    ioAct <- makeCallback act
    liftIO $ fun ioAct


withSeat :: Maybe Seat -> Way a b -> Way a b
withSeat seat (Way m) = Way $ local (const seat) m
