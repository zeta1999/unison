{-# Language OverloadedStrings, TupleSections #-}

module Unison.FileParser where

import           Control.Applicative
import           Control.Monad.Reader
import           Data.Either (partitionEithers)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Prelude hiding (readFile)
import qualified Text.Parsec.Layout as L
import           Unison.DataDeclaration (DataDeclaration, EffectDeclaration)
import qualified Unison.DataDeclaration as DD
import           Unison.Parser (Parser, traced, token_, sepBy, string)
import qualified Unison.TermParser as TermParser
import qualified Unison.Type as Type
import           Unison.TypeParser (S)
import qualified Unison.TypeParser as TypeParser
import           Unison.UnisonFile (UnisonFile(..), environmentFor)
import qualified Unison.UnisonFile as UF
import           Unison.Var (Var)
import Unison.Reference (Reference)

file :: Var v => [(v, Reference)] -> [(v, Reference)] -> Parser (S v) (UnisonFile v)
file builtinTerms builtinTypes = traced "file" $ do
  (dataDecls, effectDecls) <- traced "declarations" declarations
  let env = environmentFor builtinTerms builtinTypes dataDecls effectDecls
  local (`Map.union` UF.constructorLookup env) $ do
    term <- TermParser.block
    pure $ UnisonFile (UF.datas env) (UF.effects env) (UF.resolveTerm env term)

declarations :: Var v => Parser (S v)
                         (Map v (DataDeclaration v),
                          Map v (EffectDeclaration v))
declarations = do
  declarations <- many ((Left <$> dataDeclaration) <|> Right <$> effectDeclaration)
  let (dataDecls, effectDecls) = partitionEithers declarations
  pure (Map.fromList dataDecls, Map.fromList effectDecls)

dataDeclaration :: Var v => Parser (S v) (v, DataDeclaration v)
dataDeclaration = traced "data declaration" $ do
  token_ $ string "type"
  (name, typeArgs) <- --L.withoutLayout "type introduction" $
    (,) <$> TermParser.prefixVar <*> traced "many prefixVar" (many TermParser.prefixVar)
  traced "=" . token_ $ string "="
  -- dataConstructorTyp gives the type of the constructor, given the types of
  -- the constructor arguments, e.g. Cons becomes forall a . a -> List a -> List a
  let dataConstructorTyp ctorArgs =
        Type.foralls() typeArgs $ Type.arrows (((),) <$> ctorArgs) (Type.apps (Type.var() name) (((),) . Type.var() <$> typeArgs))
      dataConstructor =
        (,) <$> TermParser.prefixVar
            <*> (dataConstructorTyp <$> many TypeParser.valueTypeLeaf)
  traced "vblock" $ L.vblockIncrement $ do
    constructors <- traced "constructors" $ sepBy (token_ $ string "|") dataConstructor
    pure $ (name, DD.mkDataDecl typeArgs constructors)

effectDeclaration :: Var v => Parser (S v) (v, EffectDeclaration v)
effectDeclaration = traced "effect declaration" $ do
  token_ $ string "effect"
  name <- TermParser.prefixVar
  typeArgs <- many TermParser.prefixVar
  token_ $ string "where"
  L.vblockNextToken $ do
    constructors <- sepBy L.vsemi constructor
    pure $ (name, DD.mkEffectDecl typeArgs constructors)
  where
    constructor = (,) <$> (TermParser.prefixVar <* token_ (string ":")) <*> traced "computation type" TypeParser.computationType