module Engine where

import Prelude
import Data.Tuple
import Data.Maybe
import Data.Either
import Data.Array
import Data.TypedArray as T
import Data.Int (toNumber)

import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Except.Trans (ExceptT (), lift)
import Control.Monad.Reader.Trans (runReaderT)
import Control.Monad.Reader.Class (ask)
import Control.Monad.ST

import Graphics.WebGL
import Graphics.WebGL.Types (WebGLProgram, WebGLTexture, WebGLFramebuffer)
import Graphics.WebGL.Raw as GL
import Graphics.WebGL.Raw.Enums as GLE
import Graphics.WebGL.Raw.Types as GLT
import Graphics.WebGL.Types
import Graphics.WebGL.Context
import Graphics.WebGL.Shader
import Graphics.WebGL.Methods
import Graphics.Canvas (Canvas, getCanvasElementById)

import Pattern (Pattern)
import JSUtil (unsafeNull, unsafeURLGet)

-- DATA
type EngineConf = {
    kernelDim :: Int
  , fract :: Int
}

type EngineState = {
    displayProg :: WebGLProgram
  , mainProg :: WebGLProgram
  , tex :: (Tuple WebGLTexture WebGLTexture)
  , fb :: (Tuple WebGLFramebuffer WebGLFramebuffer)
  , ctx :: WebGLContext
}

defaultEngineConf :: EngineConf
defaultEngineConf = {
    kernelDim: 512
  , fract: 3
}

--defaultEngineState :: EngineState
--defaultEngineState = { }

-- PUBLIC
loadEngineConf :: forall eff. String -> ExceptT String (Eff eff) EngineConf
loadEngineConf name = do
  let engConf = defaultEngineConf
  return engConf


initTex :: Int -> WebGL (Tuple WebGLTexture WebGLFramebuffer)
initTex dim = do
  ctx <- ask
  tex <- createTexture
  fb  <- createFramebuffer
  liftEff $ GL.bindTexture ctx GLE.texture2d tex
  liftEff $ GL.texParameteri ctx GLE.texture2d GLE.textureWrapS GLE.clampToEdge
  liftEff $ GL.texParameteri ctx GLE.texture2d GLE.textureWrapT GLE.clampToEdge
  liftEff $ GL.texParameteri ctx GLE.texture2d GLE.textureMinFilter GLE.linear
  liftEff $ GL.texParameteri ctx GLE.texture2d GLE.textureMagFilter GLE.linear
  liftEff $ GL.texImage2D_ ctx GLE.texture2d 0 GLE.rgba dim dim 0 GLE.rgba GLE.unsignedByte (unsafeNull :: GLT.ArrayBufferView)
  liftEff $ GL.bindFramebuffer ctx GLE.framebuffer fb
  liftEff $ GL.framebufferTexture2D ctx GLE.framebuffer GLE.colorAttachment0 GLE.texture2d tex 0

  return $ Tuple tex fb


initShaders :: Pattern -> WebGL (Tuple WebGLProgram WebGLProgram)
initShaders pattern = do
  basicVert   <- lift $ lift $ unsafeURLGet "/shaders/basic.vert.glsl"
  mainFrag    <- lift $ lift $ unsafeURLGet "/shaders/main.frag.glsl"
  displayFrag <- lift $ lift $ unsafeURLGet "/shaders/display.frag.glsl"

  -- compile sources w/ pattern

  mainProg    <- compileShadersIntoProgram basicVert mainFrag
  displayProg <- compileShadersIntoProgram basicVert displayFrag
  displayAttr <- getAttrBindings displayProg
  mainAttr    <- getAttrBindings displayProg

  pos <- createBuffer
  bindBuffer ArrayBuffer pos
  bufferData ArrayBuffer (DataSource (T.asFloat32Array [-1.0,-1.0,1.0,-1.0,-1.0, 1.0, -1.0,1.0,1.0,-1.0,1.0,1.0])) StaticDraw

  enableVertexAttribArray mainAttr.a_position
  vertexAttribPointer mainAttr.a_position 2 Float false 0 0
  enableVertexAttribArray displayAttr.a_position
  vertexAttribPointer displayAttr.a_position 2 Float false 0 0

  return $ Tuple mainProg displayProg

initEngine :: forall h eff. String -> (STRef h EngineConf) -> (STRef h Pattern) -> ExceptT String (Eff (st :: ST h, canvas :: Canvas | eff))  (STRef h EngineState)
initEngine canvasId ecRef pRef = do

  -- these are unsafe
  Just canvas <- liftEff $ getCanvasElementById canvasId
  Just ctx <- liftEff $ getWebglContext canvas

  engineConf <- lift $ readSTRef ecRef
  pattern    <- lift $ readSTRef pRef

  let dim = engineConf.kernelDim
  res <- execGL ctx ( do
    Tuple tex0 fb0     <- initTex dim
    Tuple tex1 fb1     <- initTex dim
    Tuple main display <- initShaders pattern

    clearColor 0.0 0.0 0.0 1.0
    liftEff $ GL.clear ctx GLE.colorBufferBit
    liftEff $ GL.viewport ctx 0 0 dim dim
    return {displayProg: display, mainProg: main, tex: (Tuple tex0 tex1), fb: (Tuple fb0 fb1), ctx: ctx}
  )
  lift $ newSTRef res

render :: forall h eff. EngineConf -> EngineState -> Pattern -> Int -> ExceptT String (Eff (canvas :: Canvas, st :: ST h | eff)) Unit
render engineConf engineState pattern frameNum = do
  let ctx = engineState.ctx

  execGL ctx ( do
    -- ping pong buffers
    let tm = if frameNum `mod` 2 == 0 then fst engineState.tex else snd engineState.tex
    let td = if frameNum `mod` 2 == 1 then fst engineState.tex else snd engineState.tex
    let fb = if frameNum `mod` 2 == 1 then fst engineState.fb  else snd engineState.fb

    -- main program
    liftEff $ GL.useProgram ctx engineState.mainProg
    liftEff $ GL.bindTexture ctx GLE.texture2d tm
    liftEff $ GL.bindFramebuffer ctx GLE.framebuffer fb

    mainUnif <- getUniformBindings engineState.mainProg
    uniform1f mainUnif.kernel_dim (toNumber engineConf.kernelDim)
    uniform1f mainUnif.time (pattern.t / 1000.0)

    drawArrays Triangles 0 6

    -- display/post program
    liftEff $ GL.useProgram ctx engineState.displayProg
    liftEff $ GL.bindTexture ctx GLE.texture2d td
    liftEff $ GL.bindFramebuffer ctx GLE.framebuffer unsafeNull

    displayUnif <- getUniformBindings engineState.displayProg
    uniform1f displayUnif.kernel_dim (toNumber engineConf.kernelDim)
    drawArrays Triangles 0 6
  )


resizeViewport :: forall eff. EngineState -> Int -> Int -> ExceptT String (Eff (canvas :: Canvas | eff)) Unit
resizeViewport engineState width height = do
  execGL engineState.ctx (do
    return unit
  )

-- PRIVATE
execGL :: forall eff a. WebGLContext -> (WebGL a) -> ExceptT String (Eff (canvas :: Canvas | eff)) a
execGL ctx webGL = do
  res <- lift $ runWebgl webGL ctx
  case res of
    Left er -> throwError $ show er
    Right ret -> return ret
