> {-# LANGUAGE NoMonomorphismRestriction, OverloadedStrings #-}

Setup
=====

To parse the mess that is Wiktionary, we make use of Attoparsec, a
well-regarded parser-combinator library for Haskell.

> module Text.MediaWiki.WikiText where
> import qualified Data.ByteString.Char8 as Char8
> import qualified Data.ByteString.UTF8 as UTF8
> import qualified Data.ByteString as BS
> import Data.ByteString (ByteString)
> import qualified Text.MediaWiki.AnnotatedString as A
> import Text.MediaWiki.AnnotatedString (AnnotatedString(..), Annotation, transformA)
> import Data.Attoparsec.ByteString.Char8 hiding (endOfLine)
> import Data.Attoparsec.Combinator
> import Debug.Trace (trace)
> import Control.Applicative ((<|>), (<$>), (*>), (<*))
> import Control.Monad (when)

We're going to need to make use of Haskell's functional mapping type,
Data.Map, to represent the contents of templates.

> import Data.Map (Map)
> import qualified Data.Map as Map

Pull in some string-manipulating utilities that are defined elsewhere in
this package:

> import Text.MediaWiki.SplitUtils (splitFirst, splitLast, strictReplace)

Some common shorthand for defining parse rules:

> import Text.MediaWiki.ParseTools (nop, appendChar, textWith, textWithout,
>   skipChars, textChoices, concatMany, notFollowedByChar, possiblyEmpty,
>   delimitedSpan, aPossiblyEmpty, aTextChoices, optionMaybe)


An invocation of a template is represented as a Map from parameter names to
values.  Both the names and the values are Text.

> type TemplateData = Map ByteString ByteString


Spans of text
=============

Some formatting allows whitespace as long as it stays on the same line --
for example, the whitespace around headings and after list bullets.

> optionalSameLineSpaces :: Parser ()
> optionalSameLineSpaces = skipChars " \t"

Here we're going to define some parsers that scan through characters, within a
line, that aren't involved in any interesting Wiki syntax.

We don't worry about apostrophes here, which are perhaps the least interesting
level of Wiki syntax.  Any span of Wikitext can have double or triple
apostrophes in it to indicate bold and italic text.  Single apostrophes are, of
course, just apostrophes.

We could modify every parse rule that handles basic text to also have a case
for bold and italic spans and an exception for individual apostrophes, but
instead, we could take advantage of the fact that these spans are at the lowest
level of syntax and we want to ignore them anyway.

We'll just post-process the parse result to remove the sequences of
apostrophes, by chaining it through the `discardSpans` function.

> discardSpans :: ByteString -> ByteString
> discardSpans = (strictReplace "''" "") . (strictReplace "'''" "")

What we count as plain text has to depend on what environment we're in, such as
whether we're currently parsing a link or a template.

The `<$>` operator, also known as "liftM", seems to be the preferred Haskell
way to apply a plain function to the output of a monadic computation, such as a
successful parse. Here, it "lifts" the `discardSpans` function, of type
`ByteString -> ByteString`, into a function that transforms a parse result:
that is, a function of type `Parser ByteString -> Parser ByteString`.

> plainText :: Parser ByteString
> plainText           = discardSpans <$> textWithout "[]{}\n"
> plainTextInTemplate = discardSpans <$> textWithout "[]{}|\n"
> plainTextInArg      = discardSpans <$> textWithout "[]{}|=\n"
> plainTextInLink     = plainTextInTemplate
> urlText             = textWithout "[]| \n"

There's a quirk in Wiki syntax: things that would cause syntax errors just get
output as themselves. So sometimes, some of the characters excluded by
`plainText` are going to appear as plain text, even in contexts where they would
have a meaning -- such as a single closing bracket when two closing brackets
would end a link.

It would be excessive to actually try to simulate MediaWiki's error handling,
but we can write some expressions that allows various combinations of brackets
to be matched as plain text:

- `]]` in a context where we're not expecting to end an internal link
- `}}` in a context where we're not expecting to end a template
- A single `{` not followed by `|`
- A single `]`
- A single `}`

We don't handle single opening brackets here because those often introduce
external links. Instead, if the external link parser fails to parse a link,
it'll just return the bracket as is.

> looseBracket :: Parser ByteString
> looseBracket = oneButNotTwoOf "]}" <|> looseOpeningBrace
>
> looseOpeningBrace :: Parser ByteString
> looseOpeningBrace = do
>   char '{'
>   notFollowedByChar '{'
>   notFollowedByChar '|'
>   return "{"
>
> oneButNotTwoOf :: [Char] -> Parser ByteString
> oneButNotTwoOf chars = try (
>   do
>     c <- satisfy (inClass chars)
>     notFollowedByChar c
>     return (Char8.singleton c)
>   )
>
> extraneousCloseBrackets = string "]]" <?> "junk closing brackets"
> extraneousCloseBraces   = string "}}" <?> "junk closing braces"

Attoparsec has a misnamed combinator named `endOfLine`. I say it's misnamed
because it matches an actual line break, but doesn't match at the end of
the input.

We define `newLine` here to match the line break (I don't think we need to
handle `\r` when our input comes from XML), and `endOfLine` to also include
the end of input.

> newLine :: Parser ByteString
> newLine = string "\n"
>
> endOfLine :: Parser ByteString
> endOfLine = (endOfInput >> nop) <|> newLine <?> "end of line"

Now we can define some spans of text that handle errors, and allow line breaks
where appropriate

> messyText :: Parser ByteString
> messyText            = textChoices [plainText, looseBracket, extraneousCloseBrackets, extraneousCloseBraces, newLine] <?> "plain text"
> messyTextLine        = textChoices [plainText, looseBracket, extraneousCloseBrackets, extraneousCloseBraces]          <?> "line of plain text"
> messyTextInLink      = textChoices [plainTextInLink, looseBracket, extraneousCloseBraces, newLine]                    <?> "plain text inside link"
> messyTextInExtLink   = textChoices [plainText, oneButNotTwoOf "[{}", extraneousCloseBraces, newLine]                  <?> "plain text inside external link"
> messyTextAtEndOfLink = textChoices [plainText, looseBracket, extraneousCloseBraces, newLine]                          <?> "plain text at end of link"
> messyTextInTemplate  = textChoices [plainTextInTemplate, looseBracket, extraneousCloseBrackets, newLine]              <?> "plain text inside template"

Wikitext in general is either some big special environment like a list or a
table -- which we'll handle elsewhere -- or it's made of links, templates, and
miscellaneous text.  We'll parse templates for their meaning below, but in
situations where we don't care about templates, we simply discard their
contents using the `ignoredTemplate` rule.

> wikiTextLine :: Parser ByteString
> wikiTextLine        = textChoices [wikiTable, internalLinkText, externalLinkText, ignoredTemplate, messyTextLine]       <?> "line of wikitext"
> wikiTextInLink      = textChoices [internalLinkText, externalLinkText, ignoredTemplate, messyTextInLink]                <?> "wikitext inside link"
> wikiTextAtEndOfLink = textChoices [wikiTable, internalLinkText, externalLinkText, ignoredTemplate, messyTextAtEndOfLink]<?> "wikitext at end of link"
> wikiTextInTemplate  = textChoices [internalLinkText, externalLinkText, ignoredTemplate, messyTextInTemplate]            <?> "wikitext inside template"

Wiki syntax items
=================

Links
-----

External links appear in single brackets. They contain a URL, a space, and
the text that labels the link, such as:

    In:  [http://www.americanscientist.org/authors/detail/david-van-tassel David Van Tassel]
    Out: "David Van Tassel"

External links can have no text, in which case they just get an arbitrary
number as their text, which we'll disregard. There's also a type of external
link that is just a bare URL in the text. Its effect on the text is exactly
the same as if it weren't a link, so we can disregard that case.

The following rules extract the text of an external link.

> externalLinkText :: Parser ByteString
> externalLinkText = do
>   char '['
>   externalLinkMatch <|> return "["
>
> externalLinkMatch = do
>   schema
>   urlText
>   externalLinkLabelOrEnd
>
> schema = choice (map string ["http://", "https://", "ftp://", "news://", "irc://", "mailto:", "//"]) <?> "external link schema"
> externalLinkLabelOrEnd = externalLinkEnd <|> externalLinkLabel
> externalLinkEnd = char ']' *> return ""
> externalLinkLabel = skipSpace *> messyTextInExtLink <* externalLinkEnd

Internal links have many possible components. In general, they take the form:

    [[namespace:page#section|label]]

The only part that has to be present is the page name. If the label is not
given, then the label is the same as the page.

When parsing internal links, we return just their label. However, other
details of the link are added to the LinkState.

     In:    [[word]]
     Out:   AnnotatedString [A.makeLink {page="word"}] "word"

     In:    [[word|this word]]
     Out:   AnnotatedString [A.makeLink {page="word"}] "this word"

     In:    [[word#English]]
     Out:   AnnotatedString [A.makeLink {page="word", section="English"}] "word"

     In:    [[w:en:Word]]
     Out:   AnnotatedString [A.makeLink {namespace="w:en", page="word"}] "Word"

     In:    [[Category:English nouns]]
     Out:   AnnotatedString [A.makeLink {namespace="Category", page="English nouns"}] "English nouns"


> internalLink :: Parser AnnotatedString
> internalLink = do
>   string "[["
>   target <- plainTextInLink
>   maybeText <- optionMaybe alternateText
>   let {
>     link      = parseLink target;
>     annotated = case maybeText of
>                   Just text -> A.annotate [link] text
>                   Nothing   -> A.annotate [link] (A.page link)
>   } in do
>        string "]]"
>        return annotated
>
> internalLinkText :: Parser ByteString
> internalLinkText = A.unannotate <$> internalLink

There are complicated syntaxes on MediaWiki that look like internal links,
particularly the Image: or File: syntax, which can have multiple
vertical-bar-separated parts, and assigns properties such as alternate text to
an image, as well as a plain-text caption that has no special syntax to
introduce it -- it seems to be determined by process of elimination.

Our best guess at which part of the syntax is the caption is the last one without an equals
sign. If all parts have an equals sign, perhaps because there's an innocent equals sign in
a link's text, then we return the last part.

For example, in this image syntax:

    [[File:Ainola yard.jpg|thumb|left|Ainola, Sibelius's home from 1904 until his death|alt=A white house of north European appearance with an orange tiled roof, surrounded by trees]]

the text we want to extract is:

    Ainola, Sibelius's home from 1904 until his death

> alternateText :: Parser ByteString
> alternateText = do
>   char '|'
>   text <- wikiTextAtEndOfLink
>   return (extractLinkText text)
>
> extractLinkText :: ByteString -> ByteString
> extractLinkText text =
>   let parts      = Char8.split '|' text
>       noEquals t = not (BS.isInfixOf "=" t)
>   in last ([""] ++ parts ++ (filter noEquals parts))
>
> parseLink :: ByteString -> Annotation
> parseLink target =
>   A.makeLink {A.namespace=namespace, A.page=page, A.section=section}
>   where
>     (namespace, local) = splitLast ":" target
>     (page, section) = splitFirst "#" local

`annotatedWikiText` parses text that may or may not contain links, and returns
it in an AnnotatedString data structure. `annotatedTextFrom` is a more general
version that takes in a parsing expression that it will use to find annotated
text -- for example, if there are project-specific templates that should be
treated as links.

> annotatedTextFrom :: Parser AnnotatedString -> Parser AnnotatedString
> annotatedTextFrom expr = A.concat <$> many1 expr

> annotatedWikiText :: Parser AnnotatedString
> annotatedWikiText      = annotatedTextFrom annotatedWikiTextPiece
> annotatedWikiTextPiece = internalLink <|> simpleWikiTextPiece
> simpleWikiTextPiece    = A.fromBytes <$> choice [wikiTable, externalLinkText, ignoredTemplate, messyTextLine]


Lists
-----

Here's a hierarchical data type for describing the contents of lists, which
semantically can contain other lists.

> data ListItem = Item AnnotatedString
>               | ListHeading AnnotatedString
>               | BulletList [ListItem]
>               | OrderedList [ListItem]
>               | IndentedList [ListItem]
>               deriving (Show, Eq)

Sometimes we just want the text that the list contains. `extractText`
returns the text of the list items (whatever kind of items they are) separated
by line breaks.

> extractTextLines :: ListItem -> [AnnotatedString]
> extractTextLines (Item t) = [t]
> extractTextLines (ListHeading t) = [t]
> extractTextLines (BulletList items) = extractTextLinesFromList items
> extractTextLines (OrderedList items) = extractTextLinesFromList items
> extractTextLines (IndentedList items) = extractTextLinesFromList items
>
> extractTextLinesFromList :: [ListItem] -> [AnnotatedString]
> extractTextLinesFromList items = concat (map extractTextLines items)
>
> extractText :: ListItem -> AnnotatedString
> extractText = A.unlines . extractTextLines

> listItems :: ByteString -> Parser [ListItem]
> listItems marker = do
>   lookAhead (string marker)
>   many1 (listItem marker)
>
> listItem :: ByteString -> Parser ListItem
> listItem marker = subList marker <|> singleListItem marker

> subList :: ByteString -> Parser ListItem
> subList marker =   bulletList (appendChar marker '*')
>                <|> orderedList (appendChar marker '#')
>                <|> indentedList (appendChar marker ':')
>                <|> listHeading (appendChar marker ';')
>
> anyList :: Parser ListItem
> anyList = subList ""
>
> anyListText :: Parser AnnotatedString
> anyListText = extractText <$> anyList <?> "list"
>
> listHeading :: ByteString -> Parser ListItem
> listHeading marker = ListHeading <$> listItemContent marker
>
> singleListItem :: ByteString -> Parser ListItem
> singleListItem marker = Item <$> listItemContent marker
>
> listItemContent :: ByteString -> Parser AnnotatedString
> listItemContent marker = do
>   string marker
>   optionalSameLineSpaces
>   line <- annotatedWikiText
>   endOfLine
>   return line
>
> bulletList marker   = BulletList <$> listItems marker
> orderedList marker  = OrderedList <$> listItems marker
> indentedList marker = IndentedList <$> listItems marker
>
> isPlainItem :: ListItem -> Bool
> isPlainItem (Item s) = True
> isPlainItem _ = False


Templates
---------

A simple template looks like this:

    {{archaic}}

More complex templates take arguments, such as this translation into French:

    {{t+|fr|exemple|m}}

And very complex templates can have both positional and named arguments:

    {{t|ja|例え|tr=[[たとえ]], tatoe}}

Some templates are more detailed versions of internal links. Some are metadata
that we can simply ignore. The ultimate semantics of a template can depend both
on its contents and the section in which it appears, so these semantics need to
be defined in the parsing rules for a specific wiki such as the English
Wiktionary.

Here, we define the basic syntax of templates, and return their contents in a
standardized form as a mapping from argument names to values.

> template :: Parser TemplateData
> template = string "{{" >> (templateArgs 0)
>
> ignoredTemplate :: Parser ByteString
> ignoredTemplate = template >> nop

> templateArgs :: Int -> Parser TemplateData
> templateArgs offset = do
>   nameMaybe <- optionMaybe (try templateArgName)
>   case nameMaybe of
>     Just name -> namedArg name offset
>     Nothing -> positionalArg offset
>
> templateArgName :: Parser ByteString
> templateArgName = do
>   name <- plainTextInArg
>   string "="
>   return name
>
> namedArg :: ByteString -> Int -> Parser TemplateData
> namedArg name offset = do
>   value <- possiblyEmpty wikiTextInTemplate
>   rest <- templateRest offset
>   return (Map.insert name value rest)
>
> positionalArg :: Int -> Parser TemplateData
> positionalArg offset = do
>   value <- possiblyEmpty wikiTextInTemplate
>   rest <- templateRest (offset + 1)
>   return (Map.insert (intToString offset) value rest)
>
> templateRest :: Int -> Parser TemplateData
> templateRest offset = endOfTemplate <|> (string "|" >> templateArgs offset)
>
> endOfTemplate = string "}}" >> return Map.empty
>
> intToString :: Int -> ByteString
> intToString = UTF8.fromString . show

We can simplify some of this parsing in the case where we are looking for a
*particular* template. We start by expecting two left braces and the name
of the template, then parse the rest of the template as usual.

We set the template name as arg 0, as it would be if we were using the more
general rule for parsing template expressions.

> specificTemplate :: ByteString -> Parser TemplateData
> specificTemplate name = do
>   string (BS.append "{{" name)
>   parsed <- templateRest 1
>   return (Map.insert "0" name parsed)


Tables
------

Tables have complex formatting, and thus far we're just going to be skipping
them.

> wikiTable :: Parser ByteString
> wikiTable = wikiTableComplete
>
> wikiTableComplete :: Parser ByteString
> wikiTableComplete = delimitedSpan "{|" "|}" >> nop

MediaWiki templates can be used in horrifying ways, and one way that they're
sometimes used (particularly on Wikipedia) is to start a table that is then
ended outside the template.

We don't know which templates leave tables hanging open, but when we skip over
such a template, we'll see a bunch of lines starting with |. Lines intended as
text don't normally start with vertical bars. So we can clean up incomplete
tables by skipping over all such lines.

> wikiTableDetritus :: Parser ByteString
> wikiTableDetritus = do
>   newLine
>   string "|"
>   textWithout "\n"
>   try wikiTableDetritus <|> endOfLine


Parsing sections at a time
--------------------------

These functions are designed to take in entire sections of wikitext
(which have already been split by the parser in `Sections.lhs`) and return
the plain text that they contain.

> sectionAnnotated :: Parser AnnotatedString
> sectionAnnotated = transformA squishBlankLines <$> aPossiblyEmpty (aTextChoices [anyListText, annotatedWikiText, A.fromBytes <$> newLine]) <?> "section content"

> sectionText :: Parser ByteString
> sectionText = A.unannotate <$> sectionAnnotated
>
> squishBlankLines :: ByteString -> ByteString
> squishBlankLines s = Char8.unlines (filter isMeaningfulLine (Char8.lines s))
>
> isMeaningfulLine :: ByteString -> Bool
> isMeaningfulLine s = (BS.length s) > 0 && Char8.head s /= '|' && Char8.head s /= '!' && not (isDirective s)
> isDirective s = (Char8.isPrefixOf "__" s) && (Char8.isSuffixOf "__" s)


Entry points
------------

Here's a function to be run at the IO level, which takes in Wikitext,
outputs its plain text, and returns nothing.

> outputPlainText :: ByteString -> IO ()
> outputPlainText input =
>    case parseOnly (sectionText <* endOfInput) input of
>     Left err -> showError input err
>     Right x -> Char8.putStrLn x
>
> inspectBytes :: ByteString -> IO ()
> inspectBytes input =
>   case parseOnly (sectionAnnotated <* endOfInput) input of
>     Left err -> showError input err
>     Right (AnnotatedString links text) -> do
>       Char8.putStrLn text
>       print links
>
> inspectString :: String -> IO ()
> inspectString input = inspectBytes $ UTF8.fromString input

Showing informative errors:

> showError :: ByteString -> String -> IO ()
> showError str err = do
>   putStrLn "********"
>   putStr "parse error:"
>   print err
>   Char8.putStrLn str
>   putStrLn "********"
