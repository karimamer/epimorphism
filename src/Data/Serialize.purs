module Data.Serialize where

import Prelude
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Except.Trans (throwError)
import Control.Monad.Trans.Class (lift)
import Data.Array (cons, filter, length, replicate, uncons, zip)
import Data.Array (foldM) as A
import Data.Library (Library(..))
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set, empty) as Set
import Data.StrMap (StrMap, empty, insert, lookup, thawST)
import Data.StrMap (foldM) as S
import Data.StrMap.ST (new)
import Data.String (Pattern(..), Replacement(..), joinWith, replace, split, trim)
import Data.Tuple (Tuple(..))
import Data.Types (Component(Component), EngineConf(EngineConf), Epi, EpiS, Index, Schema, SchemaEntry(SchemaEntry), SchemaEntryType(SE_A_Cx, SE_A_St, SE_M_N, SE_M_St, SE_S, SE_B, SE_I, SE_N, SE_St), SystemConf(SystemConf), UIConf(UIConf), componentSchema, indexSchema, systemConfSchema, uiConfSchema, engineConfSchema)
import Library (parseCLst, parseLst, parseMp, parseNMp, parseSet)
import Util (dbg, boolFromStringE, fromJustE, inj, intFromStringE, numFromStringE, zipI)

foreign import unsafeSetDataTableAttr :: forall a b eff. a -> String -> String -> b -> Eff eff a
foreign import unsafeGenericDataTableImpl :: forall a r. Schema -> Schema -> (Index -> (Record r) -> a) -> (Set.Set String) -> a

unsafeGenericDataTable :: forall a r. Schema -> Schema -> (Index -> (Record r) -> a) -> a
unsafeGenericDataTable idxSchema schema construct = unsafeGenericDataTableImpl idxSchema schema construct Set.empty

class Serializable a where
  schema :: a -> Schema
  generic :: a

instance scSerializable :: Serializable SystemConf where
  schema a = systemConfSchema
  generic = unsafeGenericDataTable indexSchema systemConfSchema SystemConf

instance ecSerializable :: Serializable EngineConf where
  schema a = engineConfSchema
  generic = unsafeGenericDataTable indexSchema engineConfSchema EngineConf

instance ucSerializable :: Serializable UIConf where
  schema a = uiConfSchema
  generic = unsafeGenericDataTable indexSchema uiConfSchema UIConf

instance cSerializable :: Serializable Component where
  schema a = componentSchema
  generic = unsafeGenericDataTable indexSchema componentSchema Component


type StrObj = StrMap String

parseChunk :: forall eff. (StrMap (Array StrObj)) -> (Tuple Int String) -> Epi eff (StrMap (Array StrObj))
parseChunk res (Tuple i chunk) = do
  -- extract code block
  (Tuple chunk' code) <- case split (Pattern "&&&\n") chunk of
    [l] -> pure $ Tuple l Nothing
    [l, c] -> pure $ Tuple (l <> "&&&") (Just c)
    _ -> throwError ("Too many code blocks" <> errSuf)

  -- get data type
  let lines = zipI $ filter ((/=) "") $ map trim $ split (Pattern "\n") chunk'
  {head: (Tuple _ dataType), tail} <- fromJustE (uncons lines) ("No dataType" <> errSuf)

  -- replace &&& with code in line
  tail' <- case code of
    Nothing -> pure tail
    Just c -> do
      pure $ tail # map (\(Tuple i l) -> (Tuple i (replace (Pattern "&&&") (Replacement c) l)))

  obj <- A.foldM (parseLine chunk') empty tail'

  let arr = maybe [] id (lookup dataType res)
  let arr' = cons obj arr
  pure $ insert dataType arr' res
  where
    errSuf = "\nChunk " <> (show i) <> ":\n" <> "###" <> chunk

parseLine :: forall eff. String -> StrObj -> (Tuple Int String) -> Epi eff StrObj
parseLine chunk obj (Tuple i line) = do
  let comp = filter ((/=) "") $ split (Pattern " ") line
  {head, tail} <- fromJustE (uncons comp) ("Error parsing line " <> (show i) <> " of chunk:\n###" <> chunk)

  pure $ insert head (joinWith " " tail) obj

mapRefById :: forall eff h. (StrMap (StrMap StrObj)) -> String -> (Array StrObj) ->
              EpiS eff h (StrMap (StrMap StrObj))
mapRefById res dataType vals = do
  insert dataType <$> (A.foldM insertObj empty vals) <*> (pure res)
  where
    insertObj :: (StrMap StrObj) -> StrObj -> EpiS eff h (StrMap StrObj)
    insertObj res' obj = do
      i <- fromJustE (lookup "id" obj) "Library object missing id :("
      pure $ insert i obj res'

--emptyLibrary :: forall h. Library h
--emptyLibrary = do
--  sc <- lift $ new
--  ec <- lift $ new
--  uc <- lift $ new
--  pl <- lift $ new
--  fl <- lift $ new
--  cl <- lift $ new
--  ml <- lift $ new
--  il <- lift $ new
--  sl <- lift $ new
--  Library {
--      systemConfLib: sc
--    , engineConfLib: ec
--    , uiConfLib:     uc
--    , patternLib:    pl
--    , familyLib:     fl
--    , componentLib:  cl
--    , moduleLib:     ml
--    , imageLib:      il
--    , sectionLib:    sl
--    }


parseLibData :: forall eff h. String -> EpiS eff h (Library h)
parseLibData libData = do
  let chunks = filter ((/=) "") $ map trim $ split (Pattern "###") libData
  let res = empty
  strobjs <- A.foldM parseChunk empty (zipI chunks)
  sc <- lift $ new
  ec <- lift $ new
  uc <- lift $ new
  pl <- lift $ new
  fl <- lift $ new
  cl <- lift $ new
  ml <- lift $ new
  il <- lift $ new
  sl <- lift $ new
  lib <- pure $ Library {
      systemConfLib: sc
    , engineConfLib: ec
    , uiConfLib:     uc
    , patternLib:    pl
    , familyLib:     fl
    , componentLib:  cl
    , moduleLib:     ml
    , imageLib:      il
    , sectionLib:    sl
    , system:        Nothing
  }

  objs <- S.foldM mapRefById empty strobjs
  S.foldM instantiateChunk lib objs
  where
    instantiate :: forall a. (Serializable a) => (StrMap a) -> String -> StrObj -> EpiS eff h (StrMap a)
    instantiate res name obj = do
      insert name <$> S.foldM fields generic obj <*> (pure res)
    instantiateChunk :: Library h -> String -> (StrMap StrObj) -> EpiS eff h (Library h)
    instantiateChunk lib@(Library val) dataType objs = case dataType of
      "SystemConf" -> do
        obj <- (thawST <$> S.foldM instantiate empty objs) >>= liftEff
        pure $ Library val {systemConfLib = obj}
      "EngineConf" -> do
        obj <- (thawST <$> S.foldM instantiate empty objs) >>= liftEff
        pure $ Library val {engineConfLib = obj}
      "UIConf" -> do
        obj <- (thawST <$> S.foldM instantiate empty objs) >>= liftEff
        pure $ Library val {uiConfLib = obj}
      "Component" -> do
        obj <- (thawST <$> S.foldM instantiate empty objs) >>= liftEff
        pure $ Library val {componentLib = obj}
      _ -> pure lib
    fields :: forall a. (Serializable a) => a -> String -> String -> EpiS eff h a
    fields obj fieldName fieldVal = do
      let idx_entries  = filter (schemaSel fieldName) indexSchema
      let idx_entries' = zip idx_entries (replicate (length idx_entries) "value0")
      let entries      = filter (schemaSel fieldName) (schema obj)
      let entries'     = zip entries (replicate (length entries) "value1")
      let all_entries = idx_entries' <> entries'
      case all_entries of
        [Tuple (SchemaEntry entryType _) accs] -> do
          case entryType of
            SE_St -> do
              liftEff $ unsafeSetDataTableAttr obj accs fieldName fieldVal
            SE_N -> do
              n <- numFromStringE fieldVal
              liftEff $ unsafeSetDataTableAttr obj accs fieldName n
            SE_I -> do
              i <- intFromStringE fieldVal
              liftEff $ unsafeSetDataTableAttr obj accs fieldName i
            SE_B -> do
              b <- boolFromStringE fieldVal
              liftEff $ unsafeSetDataTableAttr obj accs fieldName b
            SE_S -> do
              s <- parseSet fieldVal
              liftEff $ unsafeSetDataTableAttr obj accs fieldName s
            SE_M_St -> do
              m <- parseMp fieldVal
              liftEff $ unsafeSetDataTableAttr obj accs fieldName m
            SE_M_N -> do
              mn <- parseMp fieldVal >>= parseNMp
              liftEff $ unsafeSetDataTableAttr obj accs fieldName mn
            SE_A_St -> do
              l <- parseLst fieldVal
              liftEff $ unsafeSetDataTableAttr obj accs fieldName l
            SE_A_Cx -> do
              cx <- parseLst fieldVal >>= parseCLst
              liftEff $ unsafeSetDataTableAttr obj accs fieldName cx
        _ -> throwError $ inj "Found %0 SchemaEntries for %1" [show $ length all_entries, fieldName]
    schemaSel n (SchemaEntry _ sen) = (n == sen)


serializeLibData :: forall eff h. Library h -> EpiS eff h String
serializeLibData lib = pure ""