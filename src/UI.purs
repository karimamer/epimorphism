module UI where

import Prelude

import Data.Maybe (Maybe (Just))
import Data.Int
import Data.StrMap (insert, member, lookup)
import Data.Maybe.Unsafe (fromJust)

import Control.Monad (when, unless)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Except.Trans (runExceptT, lift, ExceptT ())
import Control.Monad.ST

import DOM (DOM)
import Graphics.Canvas
import Data.DOM.Simple.Window
import Data.DOM.Simple.Document
import Data.DOM.Simple.Element

import Config
import Command (command)
import Util (lg)

foreign import registerEventHandler :: forall eff. (String -> Eff eff Unit) -> Eff eff Unit
foreign import registerKeyHandler :: forall eff. (String -> Eff eff String) -> Eff eff Unit
foreign import requestFullScreen :: forall eff. String -> Eff eff Unit

-- PUBLIC
initUIST :: forall eff h. STRef h UIConf -> STRef h EngineConf -> STRef h EngineST -> STRef h Pattern -> STRef h SystemConf -> STRef h (SystemST h) -> EpiS eff h (STRef h UIST)
initUIST ucRef ecRef esRef pRef scRef ssRef = do
  uiConf <- lift $ readSTRef ucRef
  let uiST = defaultUIST
  usRef <- lift $ newSTRef uiST

  initLayout uiConf
  lift $ registerEventHandler (command ucRef usRef ecRef esRef pRef scRef ssRef)
  lift $ registerKeyHandler (keyHandler ucRef usRef)

  return usRef


keyHandler :: forall eff h. STRef h UIConf -> STRef h UIST -> String -> Eff (canvas :: Canvas, dom :: DOM, st :: ST h | eff) String
keyHandler ucRef usRef char = do
  uiConf <- readSTRef ucRef
  uiST   <- readSTRef usRef

  let spd = show uiConf.keyboardSwitchSpd
  case char of
    "1" -> do
      let idx = if (member "t+" uiST.incIdx) then ((fromJust $ lookup "t+" uiST.incIdx) + 1) else 0
      let dt = insert "t+" idx uiST.incIdx
      modifySTRef usRef (\s -> s {incIdx = dt})
      return $ "scr incStd main.main_body sub:t dim:vec2 idx:" ++ (show idx) ++ " spd:" ++ spd
    "Q" -> do
      let idx = if (member "t+" uiST.incIdx) then ((fromJust $ lookup "t+" uiST.incIdx) - 1) else 0
      let dt = insert "t+" idx uiST.incIdx
      modifySTRef usRef (\s -> s {incIdx = dt})
      return $ "scr incStd main.main_body sub:t dim:vec2 idx:" ++ (show idx) ++ " spd:" ++ spd
    _   -> return $ "null"



initLayout :: forall eff. UIConf -> Epi eff Unit
initLayout uiConf = do
  let window = globalWindow
  doc <- lift $ document window
  width  <- lift $ innerWidth window
  height <- lift $ innerHeight window

  unless uiConf.fullScreen do
    -- this is unsafe
    Just c2 <- lift $ querySelector ("#" ++ uiConf.canvasId) doc
    lift $ setStyleAttr "width" (show (height - 10.0) ++ "px") c2
    lift $ setStyleAttr "height" (show (height - 11.0) ++ "px") c2

    Just console <- lift $ querySelector ("#" ++ uiConf.consoleId) doc
    lift $ setStyleAttr "width" (show (width - height - 30.0) ++ "px") console
    lift $ setStyleAttr "height" (show (height - 21.0) ++ "px") console

  when uiConf.fullScreen do
    --lift $ requestFullScreen uiConf.canvasId
    -- this is unsafe
    Just c2 <- lift $ querySelector ("#" ++ uiConf.canvasId) doc
    lift $ setStyleAttr "width" "100%" c2
    lift $ setStyleAttr "height" "100%" c2

-- hackish
showFps :: forall eff. Int -> Epi eff Unit
showFps fps = do
  let window = globalWindow
  doc <- lift $ document window
  Just fpsDiv <- lift $ querySelector ("#showfps") doc
  lift $ setInnerHTML ((show fps) ++ "fps") fpsDiv
