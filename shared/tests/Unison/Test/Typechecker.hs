{-# LANGUAGE OverloadedStrings #-}

module Unison.Test.Typechecker where

import Control.Applicative
import Control.Monad.IO.Class
import Data.Functor
import Test.Tasty
import Test.Tasty.HUnit
import Unison.Node.MemNode ()
import Unison.Reference as R
import Unison.Symbol (Symbol)
import Unison.Term as E
import Unison.Type as T
import Unison.Typechecker as Typechecker
import Unison.View (DFO)
import qualified Unison.Node as Node
import qualified Unison.Note as Note
import qualified Unison.Test.Common as Common
import qualified Unison.Test.Term as Term

type TTerm = Term.TTerm
type TType = Type (Symbol DFO)
type TEnv f = T.Env f (Symbol DFO)
type TNode = IO Common.TNode

infixr 1 -->
(-->) :: TType -> TType -> TType
(-->) = T.arrow

data StrongEq = StrongEq TType
instance Eq StrongEq where StrongEq t1 == StrongEq t2 = Typechecker.equals t1 t2
instance Show StrongEq where show (StrongEq t) = show t

env :: TNode -> TEnv IO
env node r = do
  (node, _) <- Note.lift node
  Node.typeAt node (E.ref r) mempty

synthesizesAt :: TNode -> E.Path -> TTerm -> TType -> Assertion
synthesizesAt node path e t = Note.run $ do
  (node, _) <- Note.lift node
  t2 <- Node.typeAt node e path
  _ <- Note.fromEither (Typechecker.subtype t2 t)
  _ <- Note.fromEither (Typechecker.subtype t t2)
  pure ()

checksAt :: TNode -> E.Path -> TTerm -> TType -> Assertion
checksAt node path e t = Note.run . void $
  Typechecker.synthesize (env node) (E.modify' (\e -> E.ann e t) path e)

synthesizesAndChecksAt :: TNode -> E.Path -> TTerm -> TType -> Assertion
synthesizesAndChecksAt node path e t =
  synthesizesAt node path e t >> checksAt node path e t

synthesizes :: TNode -> TTerm -> TType -> Assertion
synthesizes node e t = Note.run $ do
  t2 <- Typechecker.synthesize (env node) e
  _ <- Note.fromEither (Typechecker.subtype t2 t)
  _ <- Note.fromEither (Typechecker.subtype t t2)
  pure ()

checks :: TNode -> TTerm -> TType -> Assertion
checks node e t = void $ Note.run (Typechecker.check (env node) e t)

checkSubtype :: TType -> TType -> Assertion
checkSubtype t1 t2 = case Typechecker.subtype t1 t2 of
  Left err -> assertFailure ("subtype failure:\n" ++ show err)
  Right t2 -> pure ()

synthesizesAndChecks :: TNode -> TTerm -> TType -> Assertion
synthesizesAndChecks node e t =
  synthesizes node e t >> checks node e t

tests :: TestTree
tests = withResource Common.node (\_ -> pure ()) $ \node -> testGroup "Typechecker"
  [ testCase "alpha equivalence (type)" $ assertEqual "const"
      (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "a")
      (forall' ["x", "y"] $ T.v' "x" --> T.v' "y" --> T.v' "x")
  , testCase "subtype (1)" $ checkSubtype
      (T.lit T.Number)
      (T.lit T.Number)
  , testCase "subtype (2)" $ checkSubtype
      (forall' ["a"] $ T.v' "a")
      (T.lit T.Number)
  , testCase "subtype (3)" $ checkSubtype
      (forall' ["a"] $ T.v' "a")
      (forall' ["a"] $ T.v' "a")
  , testCase "strong equivalence (type)" $ assertEqual "types were not equal"
      (StrongEq (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "a"))
      (StrongEq (forall' ["y", "x"] $ T.v' "x" --> T.v' "y" --> T.v' "x"))
  , testCase "synthesize/check 42" $ synthesizesAndChecks node
      (E.lit (E.Number 42))
      (T.lit T.Number)
  , testCase "synthesize/check Term.id" $ synthesizesAndChecks node
      Term.id
      (forall' ["b"] $ T.v' "b" --> T.v' "b")
  , testCase "synthesize/check Term.const" $ synthesizesAndChecks node
      Term.const
      (forall' ["a", "b"] $ T.v' "a" --> T.v' "b" --> T.v' "a")
  , testCase "synthesize/check (let f = (+) in f 1)" $ synthesizesAndChecks node
      (let1' [("f", E.builtin "Number.plus")] (var' "f" `E.app` E.num 1))
      (T.lit T.Number --> T.lit T.Number)
  , testCase "synthesize/check (let blank x = _ in blank 1)" $ synthesizesAndChecks node
      (let1' [("blank", lam' ["x"] E.blank )] (var' "blank" `E.app` E.num 1))
      (forall' ["a"] $ T.v' "a")
  , testCase "synthesize/check Term.fix" $ synthesizesAndChecks node
      Term.fix
      (forall' ["a"] $ (T.v' "a" --> T.v' "a") --> T.v' "a")
  , testCase "synthesize/check Term.pingpong1" $ synthesizesAndChecks node
      Term.pingpong1
      (forall' ["a"] $ T.v' "a")
  , testCase "synthesize/check [1,2,1+1]" $ synthesizesAndChecks node
      (E.vector [E.num 1, E.num 2, E.num 1 `Term.plus` E.num 1])
      (T.lit T.Vector `T.app` T.lit T.Number)
  , testCase "synthesize/checkAt [1,2,1+1]@[Index 2]" $ synthesizesAndChecksAt node
      [E.Index 2]
      (E.vector [E.num 1, E.num 2, E.num 1 `Term.plus` E.num 1])
      (T.lit T.Number)
  ]

main :: IO ()
main = defaultMain tests