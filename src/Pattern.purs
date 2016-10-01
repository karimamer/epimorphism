module Pattern where

import Prelude
import Config (EpiS, Module, Pattern, SystemST)
import Control.Monad (when)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Except.Trans (lift)
import Control.Monad.ST (STRef, modifySTRef, newSTRef, readSTRef)
import Data.Array (cons, head, tail) as A
import Data.Maybe (Maybe(..), maybe)
import Data.Maybe.Unsafe (fromJust)
import Data.StrMap (toList, member, StrMap, foldM, fold, delete, insert, values)
import Data.String (split)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import System (loadLib)
import Util (lg, uuid)

-- find a module given an address - ie main.application.t or a reference
findModule :: forall eff h. StrMap (STRef h Module) -> Pattern -> String -> Boolean -> EpiS eff h String
findModule mpool pattern dt followSwitch = do
  case (member dt mpool) of
    true -> return dt
    false -> do
      let addr = split "." dt
      case (A.head addr) of
        Nothing -> throwError "we need data, chump"
        Just "vert" -> findModule' mpool pattern.vert (fromJust $ A.tail addr) followSwitch
        Just "disp" -> findModule' mpool pattern.disp (fromJust $ A.tail addr) followSwitch
        Just "main" -> findModule' mpool pattern.main (fromJust $ A.tail addr) followSwitch
        Just x      -> throwError $ "value should be main, vert, or disp : " ++ x


findModule' :: forall eff h. StrMap (STRef h Module) -> String -> Array String -> Boolean -> EpiS eff h String
findModule' mpool mid addr followSwitch = do
  maybe (return $ mid) handle (A.head addr)
  where
    handle mid' = do
      mRef    <- loadLib mid mpool "findModule'"
      mod     <- lift $ readSTRef mRef
      childId <- loadLib mid' mod.modules "findModule' find child"
      cRef    <- loadLib childId mpool "findModule' child ref"
      child   <- lift $ readSTRef cRef
      addr'   <- return $ fromJust $ A.tail addr

      case (child.family == "switch" && followSwitch) of
        true ->  findModule' mpool childId (A.cons "m1" addr') followSwitch
        false -> findModule' mpool childId addr' followSwitch



-- find parent module id & submodule that a module is binded to. kind of ghetto
findParent :: forall eff h. StrMap (STRef h Module) -> String -> EpiS eff h (Tuple String String)
findParent mpool mid = do
  res <- foldM handle Nothing mpool
  case res of
    Nothing -> throwError $ "module has no parent: " ++ mid
    Just x -> return x
  where
    handle :: Maybe (Tuple String String) -> String -> STRef h Module -> EpiS eff h (Maybe (Tuple String String))
    handle (Just x) _ _ = return $ Just x
    handle _ pid ref = do
      mod <- lift $ readSTRef ref
      case (fold handle2 Nothing mod.modules) of
        Nothing -> return Nothing
        Just x -> do
          return $ Just $ Tuple pid x
    handle2 :: Maybe String -> String -> String -> Maybe String
    handle2 (Just x) _ _ = Just x
    handle2 _ k cid | cid == mid = Just k
    handle2 _ _ _ = Nothing


-- IMPORTING ---

-- import the modules of a pattern into the ref pool
data ImportObj = ImportModule Module | ImportRef String
importPattern :: forall eff h. STRef h (SystemST h) -> STRef h Pattern -> EpiS eff h Unit
importPattern ssRef pRef =  do
  systemST <- lift $ readSTRef ssRef
  pattern  <- lift $ readSTRef pRef

  -- import all modules
  main <- importModule ssRef (ImportRef pattern.main)
  disp <- importModule ssRef (ImportRef pattern.disp)
  vert <- importModule ssRef (ImportRef pattern.vert)
  lift $ modifySTRef pRef (\p -> p {main = main, disp = disp, vert = vert})

  return unit


-- import a module into the ref pool
importModule :: forall eff h. STRef h (SystemST h) -> ImportObj -> EpiS eff h String
importModule ssRef obj = do
  systemST <- lift $ readSTRef ssRef
  id <- lift $ uuid
  -- find module
  mod <- case obj of
    ImportModule m -> return m
    ImportRef n -> case (member n systemST.moduleRefPool) of
      true -> do
        ref <- loadLib n systemST.moduleRefPool "reimport from pool"
        lift $ readSTRef ref
      false -> do
        minit <- loadLib n systemST.moduleLib "import module lib"
        return $ minit {libName = n}

  -- update pool
  ref <- lift $ newSTRef mod
  systemST' <- lift $ readSTRef ssRef
  let mp' = insert id ref systemST'.moduleRefPool  -- maybe check for duplicates here?
  lift $ modifySTRef ssRef (\s -> s {moduleRefPool = mp'})

  -- import children
  traverse (importChild ssRef id) (toList mod.modules)

  return id

  where
    importChild :: STRef h (SystemST h) -> String -> (Tuple String String) -> EpiS eff h Unit
    importChild ssRef mid (Tuple k v) = do
      when (v /= "") do
        systemST <- lift $ readSTRef ssRef

        -- import child
        child <- importModule ssRef (ImportRef v)

        -- update parent
        mRef <- loadLib mid systemST.moduleRefPool "import module - update parent"
        m <- lift $ readSTRef mRef
        let modules' = insert k child m.modules
        lift $ modifySTRef mRef (\m' -> m' {modules = modules'})

        return unit


-- remove a module from the ref pool
purgeModule :: forall eff h. STRef h (SystemST h) -> String -> EpiS eff h Unit
purgeModule ssRef mid = do
  when (mid /= "") do
    systemST <- lift $ readSTRef ssRef
    mRef <- loadLib mid systemST.moduleRefPool "purge module"
    mod <- lift $ readSTRef mRef

    -- delete self
    let mp = delete mid systemST.moduleRefPool
    lift $ modifySTRef ssRef (\s -> s {moduleRefPool = mp})

    -- purge children
    traverse (purgeModule ssRef) (values mod.modules)

    return unit


-- replace child subN:cid(in ref pool) with child subN:obj
replaceModule :: forall eff h. STRef h (SystemST h) -> String -> String -> String -> ImportObj -> EpiS eff h String
replaceModule ssRef mid subN cid obj = do
  systemST <- lift $ readSTRef ssRef
  mRef <- loadLib mid systemST.moduleRefPool "replace module"
  m <- lift $ readSTRef mRef

  -- import & purge
  n' <- importModule ssRef obj
  purgeModule ssRef cid

  -- update
  let mod' = insert subN n' m.modules
  lift $ modifySTRef mRef (\m' -> m' {modules = mod'})

  return n'
