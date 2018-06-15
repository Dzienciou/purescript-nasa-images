module API.NasaImages.Validation where

import Prelude

import API.NasaImages.Asset (Asset(..), Image(..))
import API.NasaImages.Search (Item(..), Metadata(..), Request(..), Result(..))
import Control.Alt ((<|>))
import Control.Monad.Aff (Aff)
import Control.Monad.Error.Class (catchError)
import Data.Argonaut (Json, jsonParser)
import Data.Array (singleton)
import Data.Either (Either(..))
import Data.Foldable (find)
import Data.Functor.Variant (SProxy(..))
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe(..))
import Data.Record.Fold (collect)
import Data.String (Pattern(..), contains)
import Data.These (These(..))
import Data.Tuple (Tuple(..))
import Data.Variant (Variant, inj)
import Network.HTTP.Affjax (AJAX, AffjaxRequest, defaultRequest)
import Network.HTTP.Affjax.Request (class Requestable)
import Network.HTTP.StatusCode (StatusCode(..))
import Polyform.Validation (V(Invalid, Valid), Validation, hoistFn, hoistFnMV, hoistFnV, lmapValidation)
import Validators.Affjax (AffjaxErrorRow, HttpErrorRow, isStatusOK, status)
import Validators.Affjax (affjax)
import Validators.Json (JsError, JsValidation, arrayOf, elem, field, int, optionalField, string)

type JsonErrorRow (err :: # Type) = (parsingError :: String | err)
type PaginationErrorRow (err :: # Type) = (invalidLinkError :: Array String | err)

affjaxRequest
  :: forall req eff errs
   . Requestable req
  => Validation
      (Aff (ajax :: AJAX | eff))
      (Array (Variant (HttpErrorRow(AffjaxErrorRow errs))))
      (AffjaxRequest req)
      String
affjaxRequest = (status isStatusOK) <<< affjax

valJson 
  :: forall m err
   . Monad m 
  => Validation m
      (Array (Variant (JsonErrorRow err)))
      String
      Json
valJson = hoistFnV \response -> case jsonParser response of
  Right js -> Valid [] js
  Left error -> Invalid  $ singleton (inj (SProxy :: SProxy "parsingError") error)

affjaxJson
  :: forall eff req errs
   . Requestable req
  => Validation
      (Aff ( ajax :: AJAX | eff))
      (Array (Variant (HttpErrorRow(AffjaxErrorRow (JsonErrorRow errs)))))
      (AffjaxRequest req)
      Json
affjaxJson = valJson <<< affjaxRequest

getJson
  :: forall eff errs
   . Validation
      (Aff ( ajax :: AJAX | eff))
      (Array (Variant (HttpErrorRow(AffjaxErrorRow (JsonErrorRow errs)))))
      String
      Json
getJson =
  affjaxJson <<< hoistFn (defaultRequest{ url = _, method = Left GET })


stringifyErrs
  :: forall m e a b
   . Show e
  => Monad m
  => Validation m (Array e) a b -> Validation m (Array String) a b
stringifyErrs = lmapValidation (map show)

metadata :: forall m err. Monad m => JsValidation m err Metadata
metadata = Metadata <$> (collect { "totalHits": field "total_hits" int })

searchItem :: forall m err. Monad m => JsValidation m err (Item String)
searchItem = Item <$> (
  { asset: _
  , description: _
  , keywords: _
  , nasaId: _
  , preview: _
  , title: _
  }
  <$> field "href" string
  <*> fromData "description" string
  <*> (field "data" $ elem 0 $ (optionalField "keywords" $ arrayOf string))
  <*> fromData "nasa_id" string
  <*> (Just <$> (field "links" $ elem 0 $ field "href" string) <|> pure Nothing)
  <*> fromData "title" string)
  where
  fromData n v = field "data" $ elem 0 $ field n v


these
  :: forall a b m err
   . Monad m
  => JsValidation m err a
  -> JsValidation m err b
  -> JsValidation m err (These a b)
these vA vB
  = Both <$> (elem 0 vA) <*> (elem 1 vB)
  <|> This <$>elem 0 vA
  <|> That <$> elem 0 vB

pagination :: forall m err. Monad m => Request -> JsValidation m (PaginationErrorRow err) (These Request Request)
pagination (Request req) = these (page "prev" (_ - 1)) (page "next" (_ + 1))
  where
  page rel p = (Tuple <$> field "rel" string <*> field "href" string) >>> hoistFnV (case _ of
    (Tuple r h) | r == rel -> pure (Request req{ page = p req.page })
    (Tuple r _) -> Invalid $ singleton (inj (SProxy :: SProxy "invalidLinkError") [rel, r]))

searchResult :: forall m err. Monad m => Request -> JsValidation m (PaginationErrorRow err) (Result String)
searchResult req = Result <$> (collect
  { href: field "href" string
  , items: field "items" $ arrayOf searchItem
  , pagination: field "links" (pagination req)
  , metadata: field "metadata" $ metadata
  })

dimensions :: forall m err. Monad m => JsValidation m err { width :: Int, height :: Int }
dimensions = { width: _, height: _ } 
  <$> ( field "EXIF:ImageWidth" int
    <|> field "File:ImageWidth" int
    <|> field "EXIF:ExifImageWidth" int)
  <*> ( field "EXIF:ImageHeight" int
    <|> field "File:ImageHeight" int
    <|> field "EXIF:ExifImageWidth" int)

findStr :: forall m. Monad m => String -> Validation m (Array String) (Array String) String
findStr s = hoistFnV $ \arr ->
  case find (contains $ Pattern s) arr of
    Nothing -> Invalid [ "Could not find string containing pattern: " <> s ]
    Just a -> pure a

asset :: forall m. Monad m => Validation m (Array String) (Array String) (Asset Unit)
asset = hoistFnV (\urls ->
  let
    a = do
      orig <- find (contains $ Pattern "orig") urls
      thumb <- find (contains $ Pattern "thumb") urls
      pure $ Asset { original: Image { url: orig, width : unit, height : unit }, thumb: thumb }
  in case a of
    Just a'  -> pure a'
    Nothing -> Invalid [ "Could not retrieve asset info" ])
