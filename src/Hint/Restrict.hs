{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeFamilies #-}

module Hint.Restrict(restrictHint) where

{-
-- These tests rely on the .hlint.yaml file in the root
<TEST>
foo = unsafePerformIO --
foo = bar `unsafePerformIO` baz --
module Util where otherFunc = unsafePerformIO $ print 1 --
module Util where exitMessageImpure = unsafePerformIO $ print 1
foo = unsafePerformOI
</TEST>
-}

import qualified Data.Map as Map
import Config.Type
import Hint.Type
import Data.List
import Data.Maybe
import Data.Semigroup
import Control.Applicative
import Control.Monad
import Prelude

import "ghc-lib-parser" HsSyn
import "ghc-lib-parser" RdrName
import "ghc-lib-parser" ApiAnnotation
import qualified "ghc-lib-parser" Module as GHC
import qualified "ghc-lib-parser" HsImpExp as GHC
import qualified "ghc-lib-parser" SrcLoc as GHC
import "ghc-lib-parser" OccName
import GHC.Util

-- FIXME: The settings should be partially applied, but that's hard to orchestrate right now
restrictHint :: [Setting] -> ModuHint
restrictHint settings scope m =
    let anns = ghcAnnotations m
        ps   = pragmas anns
        opts = flags ps
        exts = langExts ps in
    checkPragmas modu opts exts restrict ++
    maybe [] (checkImports modu $ hsmodImports (GHC.unLoc (ghcModule m))) (Map.lookup RestrictModule restrict) ++
    maybe [] (checkFunctions modu $ hsmodDecls (GHC.unLoc (ghcModule m))) (Map.lookup RestrictFunction restrict)
    where
        modu = modName (GHC.unLoc (ghcModule m))
        restrict = restrictions settings

---------------------------------------------------------------------
-- UTILITIES

data RestrictItem = RestrictItem
    {riAs :: [String]
    ,riWithin :: [(String, String)]
    ,riMessage :: Maybe String
    }
instance Semigroup RestrictItem where
    RestrictItem x1 x2 x3 <> RestrictItem y1 y2 y3 = RestrictItem (x1<>y1) (x2<>y2) (x3<>y3)
instance Monoid RestrictItem where
    mempty = RestrictItem [] [] Nothing
    mappend = (<>)

restrictions :: [Setting] -> Map.Map RestrictType (Bool, Map.Map String RestrictItem)
restrictions settings = Map.map f $ Map.fromListWith (++) [(restrictType x, [x]) | SettingRestrict x <- settings]
    where
        f rs = (all restrictDefault rs
               ,Map.fromListWith (<>) [(s, RestrictItem restrictAs restrictWithin restrictMessage) | Restrict{..} <- rs, s <- restrictName])


ideaMessage :: Maybe String -> Idea -> Idea
ideaMessage (Just message) w = w{ideaNote=[Note message]}
ideaMessage Nothing w = w{ideaNote=[noteMayBreak]}

ideaNoTo :: Idea -> Idea
ideaNoTo w = w{ideaTo=Nothing}

noteMayBreak :: Note
noteMayBreak = Note "may break the code"

within :: String -> String -> RestrictItem -> Bool
within modu func RestrictItem{..} = any (\(a,b) -> (a == modu || a == "") && (b == func || b == "")) riWithin

---------------------------------------------------------------------
-- CHECKS

checkPragmas :: String
              -> [(GHC.Located AnnotationComment, [String])]
              -> [(GHC.Located AnnotationComment, [String])]
              ->  Map.Map RestrictType (Bool, Map.Map String RestrictItem)
              -> [Idea]
checkPragmas modu flags exts mps =
  f RestrictFlag "flags" flags ++ f RestrictExtension "extensions" exts
  where
   f tag name xs =
     [(if null good then ideaNoTo else id) $ notes $ rawIdea Hint.Type.Warning ("Avoid restricted " ++ name) (ghcSpanToHSE l) c Nothing [] []
     | Just (def, mp) <- [Map.lookup tag mps]
     , (GHC.dL -> GHC.L l (AnnBlockComment c), les) <- xs
     , let (good, bad) = partition (isGood def mp) les
     , let note = maybe noteMayBreak Note . (=<<) riMessage . flip Map.lookup mp
     , let notes w = w {ideaNote=note <$> bad}
     , not $ null bad]
   isGood def mp x = maybe def (within modu "") $ Map.lookup x mp

checkImports :: String -> [LImportDecl GhcPs] -> (Bool, Map.Map String RestrictItem) -> [Idea]
checkImports modu imp (def, mp) =
    [ ideaMessage riMessage $ if not allowImport
      then ideaNoTo $ warn' "Avoid restricted module" i i []
      else warn' "Avoid restricted qualification" i (GHC.noLoc $ (GHC.unLoc i){ideclAs=GHC.noLoc . GHC.mkModuleName <$> listToMaybe riAs}) []
    | i@(GHC.dL -> GHC.L _ GHC.ImportDecl {..}) <- imp
    , let ri@RestrictItem{..} = Map.findWithDefault (RestrictItem [] [("","") | def] Nothing) (GHC.moduleNameString (GHC.unLoc ideclName)) mp
    , let allowImport = within modu "" ri
    , let allowQual = maybe True (\x -> null riAs || GHC.moduleNameString (GHC.unLoc x) `elem` riAs) ideclAs
    , not allowImport || not allowQual
    ]

checkFunctions :: String -> [LHsDecl GhcPs] -> (Bool, Map.Map String RestrictItem) -> [Idea]
checkFunctions modu decls (def, mp) =
    [ (ideaMessage riMessage $ ideaNoTo $ warn' "Avoid restricted function" x x []){ideaDecl = [dname]}
    | d <- decls
    , let dname = fromMaybe "" (declName (GHC.unLoc d))
    , x <- universeBi d :: [GHC.Located RdrName]
    , let ri@RestrictItem{..} = Map.findWithDefault (RestrictItem [] [("","") | def] Nothing) (occNameString (rdrNameOcc (GHC.unLoc x))) mp
    , not $ within modu dname ri
    ]
