{- | Here is a simple use of 'parsed' and standard @Streaming@ segmentation devices to 
     parse a file in which groups of numbers are separated by blank lines. Such a problem
     of \'nesting streams\' is described in the @conduit@ context in 
     <http://stackoverflow.com/questions/32957258/how-to-model-nested-streams-with-conduits/32961296 this StackOverflow question> 

> $ cat nums.txt
> 1
> 2
> 3
> 
> 4
> 5
> 6
> 
> 7
> 8

   We will sum the groups and stream the results to standard output:

> import Streaming
> import qualified Streaming.Prelude as S
> import qualified Data.ByteString.Streaming.Char8 as Q
> import qualified Data.Attoparsec.ByteString.Char8 as A
> import qualified Streaming.Attoparsec as SA
> import Data.Function ((&))
>
>
> lineParser = number <|> blank  where 
>    number = Just <$> A.scientific <* A.endOfLine 
>    blank  = Nothing <$ A.endOfLine
> 
> -- note we are using Data.Functor.& = flip ($) below
> main = Q.getContents           -- raw bytes from stdin
>        & SA.parsed lineParser  -- stream of parsed `Maybe Int`s; blank lines are `Nothing`
>        & void                  -- drop any unparsed nonsense at the end
>        & S.split Nothing       -- split into substreams on blank lines
>        & S.maps S.concat       -- keep `Just x` values in the sub-streams (cp. catMaybes)
>        & S.mapped S.sum        -- sum each substream
>        & S.print               -- stream results to stdout


> $ cat nums.txt | ./atto
> 6.0
> 15.0
> 15.0

-} 
module Streaming.Attoparsec
    (ParseError(..)
    , parse
    , parsed 
    , Parser
--    , module Data.Attoparsec.ByteString
    )
    where

import qualified Data.ByteString as B
import qualified Data.Attoparsec.ByteString as A
import qualified Data.Attoparsec.Internal.Types as T
import Data.Attoparsec.ByteString
    hiding (IResult(..), Result, eitherResult, maybeResult,
            parse, parseWith, parseTest)
import Streaming hiding (concats, unfold)
import Streaming.Internal (Stream (..))
import Data.ByteString.Streaming
import Data.ByteString.Streaming.Internal
import Data.Monoid 

-- | Error material from Attoparsec
data ParseError = ParseError 
   { parseMessage :: String
   , parseContexts :: [String]
   } deriving (Show, Eq, Ord)

{- | The result of a parse (@Either ParseError a@), together with the unconsumed byte stream.

>>> :set -XOverloadedStrings  -- the string literal below denotes a streaming bytestring
>>> (r,rest1) <- SA.parse (A.scientific <* A.many' A.space) "12.3  4.56  78.3   ABC" 
>>> print r
Left 12.3
>>> (s,rest2) <- SA.parse (A.scientific <* A.many' A.space) rest1
>>> print s
Left 4.56
>>> (t,rest3) <- SA.parse (A.scientific <* A.many' A.space) rest2
>>> print t
Left 78.3
>>> Q.putStrLn rest3
ABC
-}



parse
    :: Monad m =>
       A.Parser a
       -> ByteString m r
       -> m (Either ParseError a, ByteString m r)
parse parser = begin where
  begin p0 = case p0 of
    Go m        -> m >>= begin
    Empty r     -> step id (A.parse parser mempty) (return r)
    Chunk bs p1 -> if B.null bs -- attoparsec understands "" 
      then begin p1             -- as eof.
      else step (chunk bs >>) (A.parse parser bs) p1

  step diff res p0 = case res of
    T.Fail _ c m -> return (Left (ParseError m c), diff p0)
    T.Done a b   -> return (Right b, chunk a >> p0)
    T.Partial k  -> do
      let clean p = case p of  -- inspect for null chunks before
            Go m        -> m >>= clean  -- feeding attoparsec 
            Empty r     -> step diff (k mempty) (return r)
            Chunk bs p1 | B.null bs -> clean p1
                        | otherwise -> step (diff . (chunk bs >>)) (k bs) p1
      clean p0
{-#INLINABLE parse #-}
      
{-| Apply a parser repeatedly to a stream of bytes, streaming the parsed values, but 
    ending when the parser fails.or the bytes run out. 

>>> S.print $ SA.parsed (A.scientific <* A.many' A.space) $ "12.3  4.56  78.9 18.282"
12.3
4.56
78.9
18.282
-}
parsed
  :: Monad m
  => A.Parser a     -- ^ Attoparsec parser
  -> ByteString m r -- ^ Raw input
  -> Stream (Of a) m (Either (ParseError, ByteString m r) r)
parsed parser = begin
  where
    begin p0 = case p0 of  -- inspect for null chunks before feeding attoparsec 
      Empty r     -> Return (Right r)
      Chunk bs p1 | B.null bs -> begin p1
                  | otherwise -> step (chunk bs >>) (A.parse parser bs) p1
      Go m       -> Effect (fmap begin m) 
    step diffP res p0 = case res of
      A.Fail _ c m -> Return (Left (ParseError m c, diffP p0))
      A.Done bs a  | B.null bs -> Step (a :> begin p0) 
                   | otherwise -> Step (a :> begin (chunk bs >> p0))
      A.Partial k  -> do
        x <- lift (nextChunk p0)
        case x of
          Left e -> step diffP (k mempty) (return e)
          Right (bs,p1) | B.null bs -> step diffP res p1
                        | otherwise  -> step (diffP . (chunk bs >>)) (k bs) p1
{-# INLINABLE parsed #-}


