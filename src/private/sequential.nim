# file must be included from yaml.nim and cannot compile on its own

type
    YamlParserState = enum
        ypInitial, ypSkipDirective, ypBlockLineStart, ypBlockAfterTag,
        ypBlockAfterAnchor, ypBlockAfterAnchorAndTag, ypBlockAfterScalar,
        ypBlockAfterAlias, ypBlockAfterColon, ypBlockMultilineScalar,
        ypBlockLineEnd, ypBlockScalarHeader, ypBlockScalar, ypFlow,
        ypFlowAfterObject, ypFlowAfterTag, ypFlowAfterAnchor,
        ypFlowAfterAnchorAndTag, ypExpectingDocumentEnd, ypAfterDirectivesEnd
    
    DocumentLevelMode = enum
        mBlockSequenceItem, mFlowSequenceItem, mExplicitBlockMapKey,
        mImplicitBlockMapKey, mBlockMapValue, mFlowMapKey, mFlowMapValue,
        mScalar, mUnknown
    
    DocumentLevel = object
        mode: DocumentLevelMode
        indicatorColumn: int
        indentationColumn: int
    
    LineStrippingMode = enum
        lsStrip, lsClip, lsKeep
    
    BlockScalarStyle = enum
        bsLiteral, bsFolded

proc newParser*(tagLib: YamlTagLibrary): YamlSequentialParser =
    new(result)
    result.tagLib = tagLib
    result.anchors = initOrderedTable[string, AnchorId]()

proc anchor*(parser: YamlSequentialParser, id: AnchorId): string =
    for pair in parser.anchors.pairs:
        if pair[1] == id:
            return pair[0]
    return nil

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool =
    if left.kind != right.kind:
        return false
    case left.kind
    of yamlStartDocument, yamlEndDocument, yamlEndMap, yamlEndSequence:
        result = true
    of yamlStartMap:
        result = left.mapAnchor == right.mapAnchor and
                 left.mapTag == right.mapTag
    of yamlStartSequence:
        result = left.seqAnchor == right.seqAnchor and
                 left.seqTag == right.seqTag
    of yamlScalar:
        result = left.scalarAnchor == right.scalarAnchor and
                 left.scalarTag == right.scalarTag and
                 left.scalarContent == right.scalarContent and
                 left.scalarType == right.scalarType
    of yamlAlias:
        result = left.aliasTarget == right.aliasTarget
    of yamlError, yamlWarning:
        result = left.description == right.description and
                 left.line == right.line and left.column == right.column

proc `$`*(event: YamlStreamEvent): string =
    result = $event.kind & '('
    case event.kind
    of yamlEndMap, yamlEndSequence, yamlStartDocument, yamlEndDocument:
        discard
    of yamlStartMap:
        result &= "tag=" & $event.mapTag
        if event.mapAnchor != anchorNone:
            result &= ", anchor=" & $event.mapAnchor
    of yamlStartSequence:
        result &= "tag=" & $event.seqTag
        if event.seqAnchor != anchorNone:
            result &= ", anchor=" & $event.seqAnchor
    of yamlScalar:
        result &= "tag=" & $event.scalarTag
        if event.scalarAnchor != anchorNone:
            result &= ", anchor=" & $event.scalarAnchor
        result &= ", typeHint=" & $event.scalarType
        result &= ", content=\"" & event.scalarContent & '\"'
    of yamlAlias:
        result &= "aliasTarget=" & $event.aliasTarget
    of yamlWarning, yamlError:
        result &= "line=" & $event.line & ", column=" & $event.column
        result &= ", description=\"" & event.description & '\"'
    result &= ")"
        
template yieldWarning(d: string) {.dirty.} =
    yield YamlStreamEvent(kind: yamlWarning, description: d,
                          line: lex.line, column: lex.column)

template yieldError(d: string) {.dirty.} =
    yield YamlStreamEvent(kind: yamlError, description: d,
                          line: lex.line, column: lex.column)
    break parserLoop

template yieldUnexpectedToken(expected: string = "") {.dirty.} =
    var msg = "[" & $state & "] Unexpected token"
    if expected.len > 0:
        msg.add(" (expected " & expected & ")")
    msg.add(": " & $token)
    yieldError(msg)

proc resolveAnchor(parser: YamlSequentialParser, anchor: var string):
        AnchorId {.inline.} =
    result = anchorNone
    if anchor.len > 0:
        result = cast[AnchorId](parser.anchors.len)
        if parser.anchors.hasKeyOrPut(anchor, result):
            result = parser.anchors[anchor]
    anchor = ""

proc resolveAlias(parser: YamlSequentialParser, name: string): AnchorId =
    try:
        result = parser.anchors[name]
    except KeyError:
        result = anchorNone

proc resolveTag(parser: YamlSequentialParser, tag: var string,
                quotedString: bool = false): TagId {.inline.} =
    if tag.len == 0:
        result = if quotedString: tagExclamationMark else: tagQuestionMark
    else:
        try:
            result = parser.tagLib.tags[tag]
        except KeyError:
            result = parser.tagLib.registerUri(tag)
        tag = ""

template yieldScalar(content: string, typeHint: YamlTypeHint,
                     quoted: bool = false) {.dirty.} =
    when defined(yamlDebug):
        echo "Parser token [mode=", level.mode, ", state=", state, "]: ",
             "scalar[\"", content, "\", type=", typeHint, "]"
    if objectTag.len > 0:
        if tag.len > 0:
            yieldError("Duplicate tag for scalar")
        tag = objectTag
    yield YamlStreamEvent(kind: yamlScalar,
            scalarAnchor: resolveAnchor(parser, anchor),
            scalarTag: resolveTag(parser, tag, quoted),
            scalarContent: content,
            scalarType: typeHint)

template yieldStartMap() {.dirty.} =
    when defined(yamlDebug):
        echo "Parser token [mode=", level.mode, ", state=", state, "]: yamlStartMap"
    yield YamlStreamEvent(kind: yamlStartMap,
                          mapAnchor: resolveAnchor(parser, anchor),
                          mapTag: resolveTag(parser, tag))

template yieldStartSequence() {.dirty.} =
    when defined(yamlDebug):
        echo "Parser token [mode=", level.mode, ", state=", state, "]: yamlStartSequence"
    yield YamlStreamEvent(kind: yamlStartSequence,
                          seqAnchor: resolveAnchor(parser, anchor),
                          seqTag: resolveTag(parser, tag))

template yieldStart(t: YamlStreamEventKind) {.dirty.} =
    when t == yamlStartMap:
        yieldStartMap()
    else:
        yieldStartSequence()

template yieldDocumentEnd() {.dirty.} =
    yield YamlStreamEvent(kind: yamlEndDocument)
    tagShorthands = initTable[string, string]()
    tagShorthands["!"] = "!"
    tagShorthands["!!"] = "tag:yaml.org,2002:"
    parser.anchors = initOrderedTable[string, AnchorId]()

template closeLevel(lvl: DocumentLevel) {.dirty.} =
    case lvl.mode
    of mExplicitBlockMapKey, mFlowMapKey:
        yieldScalar("", yTypeUnknown)
        yield YamlStreamEvent(kind: yamlEndMap)
    of mImplicitBlockMapKey, mBlockMapValue, mFlowMapValue:
        yield YamlStreamEvent(kind: yamlEndMap)
    of mBlockSequenceItem, mFlowSequenceItem:
        yield YamlStreamEvent(kind: yamlEndSequence)
    of mScalar:
        when defined(yamlDebug):
            echo "Parser token [mode=", level.mode, ", state=", state, "]: ",
                 "scalar[\"", scalarCache, "\", type=", scalarCacheType, "]"
        yield YamlStreamEvent(kind: yamlScalar,
                              scalarAnchor: resolveAnchor(parser, anchor),
                              scalarTag: resolveTag(parser, tag),
                              scalarContent: scalarCache,
                              scalarType: scalarCacheType)
        
    else:
        yieldScalar("", yTypeUnknown)

proc mustLeaveLevel(curCol: int, ancestry: seq[DocumentLevel]): bool =
    if ancestry.len == 0:
        result = false
    else:
        let parent = ancestry[ancestry.high]
        result = parent.indicatorColumn >= curCol or
                (parent.indicatorColumn == -1 and
                 parent.indentationColumn >= curCol)

template leaveMoreIndentedLevels() {.dirty.} =
    while ancestry.len > 0:
        let parent = ancestry[ancestry.high]
        if parent.indicatorColumn >= lex.column or
                 (parent.indicatorColumn == -1 and
                  parent.indentationColumn >= lex.column):
            closeLevel(level)
            level = ancestry.pop()
            if level.mode == mBlockMapValue:
                level.mode = mImplicitBlockMapKey
        else:
            break
           
template closeAllLevels() {.dirty.} =
    while true:
        closeLevel(level)
        if ancestry.len == 0: break
        level = ancestry.pop()

template handleBlockIndicator(expected, possible: openarray[DocumentLevelMode],
                              next: DocumentLevelMode,
                              entering: YamlStreamEventKind,
                              emptyScalarOnOpening: bool = false) {.dirty.} =
    leaveMoreIndentedLevels()
    if level.indicatorColumn == lex.column or
          level.indicatorColumn == -1 and level.indentationColumn == lex.column:
        if level.mode in expected:
            level.mode = next
            ancestry.add(level)
            level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                  indentationColumn: -1)
        else:
            # `in` does not work if possible is [], so we have to check for that
            when possible.len > 0:
                if level.mode in possible:
                    yieldScalar("", yTypeUnknown)
                    level.mode = next
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                else:
                    yieldError("Invalid token after " & $level.mode)
            else:
                yieldError("Invalid token after " & $level.mode)
    elif level.mode != mUnknown:
        yieldError("Invalid indentation")
    elif entering == yamlError:
        yieldUnexpectedToken()
    else:
        level.mode = next
        level.indicatorColumn = lex.column
        if emptyScalarOnOpening:
            # do not consume anchor and tag; they are on the scalar
            var
                cachedAnchor = anchor
                cachedTag    = tag
            anchor = ""
            tag = objectTag
            yieldStart(entering)
            anchor = cachedAnchor
            tag = cachedTag
            yieldScalar("", yTypeUnknown)
        else:
            yieldStart(entering)
        ancestry.add(level)
        level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                              indentationColumn: -1)

template startPlainScalar() {.dirty.} =
    level.mode = mScalar
    level.indentationColumn = lex.column
    scalarCache = lex.content
    scalarCacheType = lex.typeHint
    scalarIndentation = lex.column
    state = ypBlockAfterScalar

template handleTagHandle() {.dirty.} =
    let handle = lex.content
    if tagShorthands.hasKey(handle):
        token = nextToken(lex)
        if finished(nextToken):
            yieldError("Missing tag suffix")
            continue
        if token != tTagSuffix:
            yieldError("Missing tag suffix")
            continue
        tag = tagShorthands[handle] & lex.content
        if level.indentationColumn == -1 and level.indicatorColumn == -1:
            level.indentationColumn = lex.column
    else:
        yieldError("Unknown tag shorthand: " & handle)

proc parse*(parser: YamlSequentialParser, s: Stream): YamlStream =
  result = iterator(): YamlStreamEvent =
    var
        # parsing state
        lex: YamlLexer
        state = ypInitial
        
        # document state
        foundYamlDirective = false
        tagShorthands = initTable[string, string]()
        
        # object tree state
        ancestry = newSeq[DocumentLevel]()
        level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                              indentationColumn: -1)
        
        # block scalar state
        lineStrip: LineStrippingMode
        blockScalar: BlockScalarStyle
        blockScalarIndentation: int
        blockScalarTrailing: string = nil
        
        # cached values
        tag: string = ""
        objectTag: string = ""
        anchor: string = ""
        scalarCache: string = nil
        scalarCacheType: YamlTypeHint
        scalarIndentation: int
        scalarCacheIsQuoted: bool = false
        aliasCache = anchorNone
        
    lex.open(s)
    tagShorthands["!"] = "!"
    tagShorthands["!!"] = "tag:yaml.org,2002:"
    
    var nextToken = tokens
    var token = nextToken(lex)
    block parserLoop:
      while not finished(nextToken):
        case state
        of ypInitial:
            case token
            of tYamlDirective:
                if foundYamlDirective:
                    yieldError("Duplicate %YAML directive")
                var
                    warn = false
                    actualVersion = ""
                for version in [1, 2]:
                    token = nextToken(lex)
                    if finished(nextToken):
                        yieldError("Missing or badly formatted YAML version")
                    if token != tVersionPart:
                        yieldError("Missing or badly formatted YAML version")
                    if parseInt(lex.content) != version:
                        warn = true
                    if actualVersion.len > 0: actualVersion &= "."
                    actualVersion &= $version
                if warn:
                    yieldWarning("Unsupported version: " & actualVersion &
                                 ", trying to parse anyway")
                foundYamlDirective = true
            of tTagDirective:
                token = nextToken(lex)
                if finished(nextToken):
                    yieldError("Incomplete %TAG directive")
                if token != tTagHandle:
                    yieldError("Invalid token (expected tag handle)")
                let tagHandle = lex.content
                token = nextToken(lex)
                if finished(nextToken):
                    yieldError("Incomplete %TAG directive")
                if token != tTagURI:
                    yieldError("Invalid token (expected tag URI)")
                tagShorthands[tagHandle] = lex.content
            of tUnknownDirective:
                yieldWarning("Unknown directive: " & lex.content)
                state = ypSkipDirective
            of tComment:
                discard
            of tDirectivesEnd:
                yield YamlStreamEvent(kind: yamlStartDocument)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                state = ypAfterDirectivesEnd
            of tDocumentEnd, tStreamEnd:
                yield YamlStreamEvent(kind: yamlStartDocument)
                yieldDocumentEnd()
            else:
                yield YamlStreamEvent(kind: yamlStartDocument)
                state = ypBlockLineStart
                continue
        of ypSkipDirective:
            if token notin [tUnknownDirectiveParam, tTagHandle,
                            tTagURI, tVersionPart, tComment]:
                state = ypInitial
                continue
        of ypAfterDirectivesEnd:
            case token
            of tTagHandle:
                handleTagHandle()
                objectTag = tag
                tag = ""
                state = ypBlockLineEnd
            of tComment:
                state = ypBlockLineEnd
            of tLineStart:
                state = ypBlockLineStart
            else:
                yieldUnexpectedToken()
        of ypBlockLineStart:
            case token
            of tLineStart:
                if objectTag.len > 0:
                    yieldError("Duplicate tag for object")
                else:
                    objectTag = tag
                    tag = ""
            of tDash:
                handleBlockIndicator([mBlockSequenceItem], [],
                                     mBlockSequenceItem, yamlStartSequence)
            of tQuestionmark:
                handleBlockIndicator([mImplicitBlockMapKey, mBlockMapValue],
                                     [mExplicitBlockMapKey],
                                     mExplicitBlockMapKey, yamlStartMap)
            of tColon:
                handleBlockIndicator([mExplicitBlockMapKey],
                                     [mBlockMapValue, mImplicitBlockMapKey],
                                     mBlockMapValue, yamlStartMap, true)
            of tPipe, tGreater:
                blockScalar = if token == tPipe: bsLiteral else: bsFolded
                blockScalarIndentation = -1
                lineStrip = lsClip
                state = ypBlockScalarHeader
                scalarCache = ""
                level.mode = mScalar
            of tTagHandle:
                leaveMoreIndentedLevels()
                handleTagHandle()
                level.indentationColumn = lex.column
                state = ypBlockAfterTag
            of tVerbatimTag:
                tag = lex.content
                state = ypBlockAfterTag
                level.indentationColumn = lex.column
            of tAnchor:
                leaveMoreIndentedLevels()
                anchor = lex.content
                level.indentationColumn = lex.column
                state = ypBlockAfterAnchor
            of tScalarPart:
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown:
                    startPlainScalar()
                    level.indentationColumn = lex.column
                of mImplicitBlockMapKey:
                    scalarCache = lex.content
                    scalarCacheType = lex.typeHint
                    scalarCacheIsQuoted = false
                    scalarIndentation = lex.column
                of mBlockMapValue:
                    scalarCache = lex.content
                    scalarCacheType = lex.typeHint
                    scalarCacheIsQuoted = false
                    scalarIndentation = lex.column
                    level.mode = mImplicitBlockMapKey
                of mExplicitBlockMapKey:
                    yieldScalar("", yTypeUnknown)
                    level.mode = mBlockMapValue
                    continue
                else:
                    yieldError("Unexpected scalar in " & $level.mode)
                state = ypBlockAfterScalar
            of tScalar:
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown, mImplicitBlockMapKey:
                    scalarCache = lex.content
                    scalarCacheType = yTypeString
                    scalarCacheIsQuoted = true
                    scalarIndentation = lex.column
                    state = ypBlockAfterScalar
                else:
                    yieldError("Unexpected scalar")
            of tAlias:
                aliasCache = resolveAlias(parser, lex.content)
                if aliasCache == anchorNone:
                    yieldError("[alias] Unknown anchor: " & lex.content)
                if ancestry.len > 0:
                    if level.mode == mUnknown:
                        level = ancestry.pop()
                else:
                    assert level.mode == mImplicitBlockMapKey
                leaveMoreIndentedLevels()
                case level.mode
                of mUnknown, mImplicitBlockMapKey, mBlockSequenceItem:
                    state = ypBlockAfterAlias
                else:
                    yieldError("Unexpected alias")
            of tStreamEnd:
                closeAllLevels()
                yield YamlStreamEvent(kind: yamlEndDocument)
                break
            of tDocumentEnd:
                closeAllLevels()
                yieldDocumentEnd()
                state = ypInitial
            of tOpeningBrace:
                state = ypFlow
                continue
            of tOpeningBracket:
                state = ypFlow
                continue
            else:
                yieldUnexpectedToken()
        of ypBlockMultilineScalar:            
            case token
            of tScalarPart:
                leaveMoreIndentedLevels()
                if level.mode != mScalar:
                    state = ypBlockLineStart
                    continue
                scalarCache &= " " & lex.content
                scalarCacheType = yTypeUnknown
                state = ypBlockLineEnd
            of tLineStart:
                discard
            of tColon, tDash, tQuestionmark:
                leaveMoreIndentedLevels()
                if level.mode != mScalar:
                    state = ypBlockLineStart
                    continue
                yieldUnexpectedToken()
            of tDocumentEnd, tStreamEnd:
                state = ypBlockLineStart
                continue
            else:
                leaveMoreIndentedLevels()
                if level.mode == mScalar:
                    yieldUnexpectedToken()
                state = ypBlockLineStart
                continue
        of ypBlockAfterScalar:
            case token
            of tColon:
                assert level.mode in [mUnknown, mImplicitBlockMapKey, mScalar]
                if level.mode in [mUnknown, mScalar]:
                    yield YamlStreamEvent(kind: yamlStartMap,
                                          mapAnchor: anchorNone,
                                          mapTag: parser.resolveTag(objectTag))
                level.mode = mBlockMapValue
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                yieldScalar(scalarCache, scalarCacheType, scalarCacheIsQuoted)
                scalarCache = nil
                state = ypBlockAfterColon
            of tLineStart:
                if level.mode == mImplicitBlockMapKey:
                    yieldError("Missing colon after implicit map key")
                if level.mode != mScalar:
                    yieldScalar(scalarCache, scalarCacheType,
                                scalarCacheIsQuoted)
                    scalarCache = nil
                    if ancestry.len > 0:
                        level = ancestry.pop()
                    else:
                        state = ypExpectingDocumentEnd
                else:
                    state = ypBlockMultilineScalar
            of tStreamEnd:
                yieldScalar(scalarCache, scalarCacheType, scalarCacheIsQuoted)
                scalarCache = nil
                if ancestry.len > 0:
                    level = ancestry.pop()
                    closeAllLevels()
                yield YamlStreamEvent(kind: yamlEndDocument)
                break
            else:
                yieldUnexpectedToken()
        of ypBlockAfterAlias:
            case token
            of tColon:
                assert level.mode in [mUnknown, mImplicitBlockMapKey]
                if level.mode == mUnknown:
                    yield YamlStreamEvent(kind: yamlStartMap,
                                          mapAnchor: anchorNone,
                                          mapTag: tagQuestionMark)
                level.mode = mBlockMapValue
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
                yield YamlStreamEvent(kind: yamlAlias, aliasTarget: aliasCache)
                state = ypBlockAfterColon
            of tLineStart:
                if level.mode == mImplicitBlockMapKey:
                    yieldError("Missing colon after implicit map key")
                if level.mode == mUnknown:
                    assert ancestry.len > 0
                    level = ancestry.pop()
                yield YamlStreamEvent(kind: yamlAlias, aliasTarget: aliasCache)
                state = ypBlockLineStart
            of tStreamEnd:
                yield YamlStreamEvent(kind: yamlAlias, aliasTarget: aliasCache)
                if level.mode == mUnknown:
                    assert ancestry.len > 0
                    level = ancestry.pop()
                state = ypBlockLineEnd
                continue
            else:
                yieldUnexpectedToken()
        of ypBlockAfterTag:
            if mustLeaveLevel(lex.column, ancestry):
                leaveMoreIndentedLevels()
                state = ypBlockLineStart
                continue
            case token
            of tAnchor:
                anchor = lex.content
                state = ypBlockAfterAnchorAndTag
            of tScalar, tColon, tStreamEnd, tScalarPart:
                state = ypBlockLineStart
                continue
            of tLineStart:
                state = ypBlockLineStart
            of tOpeningBracket, tOpeningBrace:
                state = ypFlow
                continue
            else:
                yieldUnexpectedToken()
        of ypBlockAfterAnchor:
            if mustLeaveLevel(lex.column, ancestry):
                leaveMoreIndentedLevels()
                state = ypBlockLineStart
                continue
            case token
            of tScalar, tColon, tStreamEnd, tScalarPart:
                state = ypBlockLineStart
                continue
            of tLineStart:
                discard
            of tOpeningBracket, tOpeningBrace:
                state = ypFlow
                continue
            of tTagHandle:
                handleTagHandle()
                state = ypBlockAfterAnchorAndTag
            of tVerbatimTag:
                tag = lex.content
                state = ypBlockAfterAnchorAndTag
                level.indentationColumn = lex.column
            else:
                yieldUnexpectedToken()
        of ypBlockAfterAnchorAndTag:
            if mustLeaveLevel(lex.column, ancestry):
                leaveMoreIndentedLevels()
                state = ypBlockLineStart
                continue
            case token
            of tScalar, tColon, tStreamEnd, tScalarPart:
                state = ypBlockLineStart
                continue
            of tLineStart:
                discard
            of tOpeningBracket, tOpeningBrace:
                state = ypFlow
                continue
            else:
                yieldUnexpectedToken()
        of ypBlockAfterColon:
            case token
            of tScalar:
                yieldScalar(lex.content, yTypeUnknown, true)
                level = ancestry.pop()
                assert level.mode == mBlockMapValue
                level.mode = mImplicitBlockMapKey
                state = ypBlockLineEnd
            of tScalarPart:
                startPlainScalar()
            of tLineStart:
                state = ypBlockLineStart
            of tStreamEnd:
                closeAllLevels()
                yield YamlStreamEvent(kind: yamlEndDocument)
                break
            of tOpeningBracket, tOpeningBrace:
                state = ypFlow
                continue
            of tPipe, tGreater:
                blockScalar = if token == tPipe: bsLiteral else: bsFolded
                blockScalarIndentation = -1
                lineStrip = lsClip
                state = ypBlockScalarHeader
                scalarCache = ""
                level.mode = mScalar
            of tTagHandle:
                handleTagHandle()
                state = ypBlockAfterTag
            of tAnchor:
                level.indentationColumn = lex.column
                anchor = lex.content
                state = ypBlockAfterAnchor
            of tAlias:
                var noAnchor = false
                try:
                    aliasCache = parser.anchors[lex.content]
                except KeyError:
                    noAnchor = true
                if noAnchor:
                    # cannot use yield within try/except, so do it here
                    yieldError("[alias] Unknown anchor: " & lex.content)
                yield YamlStreamEvent(kind: yamlAlias, aliasTarget: aliasCache)
                level = ancestry.pop()
                state = ypBlockLineEnd
            else:
                yieldUnexpectedToken("scalar or line end")
        of ypBlockLineEnd:
            case token
            of tLineStart:
                state = if level.mode == mScalar: ypBlockMultilineScalar else:
                        ypBlockLineStart
            of tStreamEnd:
                closeAllLevels()
                yield YamlStreamEvent(kind: yamlEndDocument)
                break
            else:
                yieldUnexpectedToken("line end")
        of ypBlockScalarHeader:
            case token
            of tPlus:
                if lineStrip != lsClip:
                    yieldError("Multiple chomping indicators!")
                else:
                    lineStrip = lsKeep
            of tDash:
                if lineStrip != lsClip:
                    yieldError("Multiple chomping indicators!")
                else:
                    lineStrip = lsStrip
            of tBlockIndentationIndicator:
                if blockScalarIndentation != -1:
                    yieldError("Multiple indentation indicators!")
                else:
                    blockScalarIndentation = parseInt(lex.content)
            of tLineStart:
                blockScalarTrailing = ""
                state = ypBlockScalar
            else:
                yieldUnexpectedToken()
        of ypBlockScalar:
            case token
            of tLineStart:
                if level.indentationColumn == -1:
                    discard
                else:
                    case blockScalar
                    of bsLiteral:
                        blockScalarTrailing &= "\x0A"
                    of bsFolded:
                        case blockScalarTrailing.len
                        of 0:
                            blockScalarTrailing = " "
                        of 1:
                            blockScalarTrailing = "\x0A"
                        else:
                            discard
                    
                    if lex.content.len > level.indentationColumn:
                        if blockScalar == bsFolded:
                            if blockScalarTrailing == " ":
                                blockScalarTrailing = "\x0A"
                        scalarCache &= blockScalarTrailing &
                                lex.content[level.indentationColumn..^1]
                        blockScalarTrailing = ""
                            
            of tScalarPart:
                if ancestry.high > 0:
                    if ancestry[ancestry.high].indicatorColumn >= lex.column or
                       ancestry[ancestry.high].indicatorColumn == -1 and
                       ancestry[ancestry.high].indentationColumn >= lex.column:
                            # todo: trailing chomping?
                            closeLevel(level)
                            state = ypBlockLineStart
                            continue
                if level.indentationColumn == -1:
                    level.indentationColumn = lex.column
                else:
                    scalarCache &= blockScalarTrailing
                    blockScalarTrailing = ""
                scalarCache &= lex.content
            else:
                case lineStrip
                of lsStrip:
                    discard
                of lsClip:
                    scalarCache &= "\x0A"
                of lsKeep:
                    scalarCache &= blockScalarTrailing
                closeLevel(level)
                if ancestry.len == 0:
                    state = ypExpectingDocumentEnd
                else:
                    level = ancestry.pop()
                    state = ypBlockLineStart
                continue            
        of ypFlow:
            case token
            of tLineStart:
                discard
            of tScalar:
                yieldScalar(lex.content, yTypeUnknown, true)
                level = ancestry.pop()
                state = ypFlowAfterObject
            of tScalarPart:
                yieldScalar(lex.content, lex.typeHint)
                level = ancestry.pop()
                state = ypFlowAfterObject
            of tColon:
                yieldScalar("", yTypeUnknown)
                level = ancestry.pop()
                if level.mode == mFlowMapKey:
                    level.mode = mFlowMapValue
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                else:
                    yieldUnexpectedToken("scalar, comma or map end")
            of tComma:
                yieldScalar("", yTypeUnknown)
                level = ancestry.pop()
                case level.mode
                of mFlowMapValue:
                    level.mode = mFlowMapKey
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                of mFlowSequenceItem:
                    yieldScalar("", yTypeUnknown)
                else:
                    yieldError("Internal error! Please report this bug.")
            of tOpeningBrace:
                if level.mode != mUnknown:
                    yieldUnexpectedToken()
                level.mode = mFlowMapKey
                yieldStart(yamlStartMap)
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
            of tOpeningBracket:
                if level.mode != mUnknown:
                    yieldUnexpectedToken()
                level.mode = mFlowSequenceItem
                yieldStart(yamlStartSequence)
                ancestry.add(level)
                level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                      indentationColumn: -1)
            of tClosingBrace:
                if level.mode == mUnknown:
                    yieldScalar("", yTypeUnknown)
                    level = ancestry.pop()
                if level.mode != mFlowMapValue:
                    yieldUnexpectedToken()
                yield YamlStreamEvent(kind: yamlEndMap)
                if ancestry.len > 0:
                    level = ancestry.pop()
                    case level.mode
                    of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                        state = ypFlowAfterObject
                    else:
                        state = ypBlockLineEnd
                else:
                    state = ypExpectingDocumentEnd
            of tClosingBracket:
                if level.mode == mUnknown:
                    yieldScalar("", yTypeUnknown)
                    level = ancestry.pop()
                if level.mode != mFlowSequenceItem:
                    yieldUnexpectedToken()
                else:
                    yield YamlStreamEvent(kind: yamlEndSequence)
                    if ancestry.len > 0:
                        level = ancestry.pop()
                        case level.mode
                        of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                            state = ypFlowAfterObject
                        else:
                            state = ypBlockLineEnd
                    else:
                        state = ypExpectingDocumentEnd
            of tTagHandle:
                handleTagHandle()
                state = ypFlowAfterTag
            of tAnchor:
                anchor = lex.content
                state = ypFlowAfterAnchor
            of tAlias:
                yield YamlStreamEvent(kind: yamlAlias,
                        aliasTarget: resolveAlias(parser, lex.content))
                state = ypFlowAfterObject
                level = ancestry.pop()
            else:
                yieldUnexpectedToken()
        of ypFlowAfterTag:
            case token
            of tTagHandle:
                yieldError("Multiple tags on same node!")
            of tAnchor:
                anchor = lex.content
                state = ypFlowAfterAnchorAndTag
            else:
                state = ypFlow
                continue
        of ypFlowAfterAnchor:
            case token
            of tAnchor:
                yieldError("Multiple anchors on same node!")
            of tTagHandle:
                handleTagHandle()
                state = ypFlowAfterAnchorAndTag
            else:
                state = ypFlow
                continue
        of ypFlowAfterAnchorAndTag:
            case token
            of tAnchor:
                yieldError("Multiple anchors on same node!")
            of tTagHandle:
                yieldError("Multiple tags on same node!")
            else:
                state = ypFlow
                continue
        of ypFlowAfterObject:
            case token
            of tLineStart:
                discard
            of tColon:
                if level.mode != mFlowMapKey:
                    yieldUnexpectedToken()
                else:
                    level.mode = mFlowMapValue
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                    state = ypFlow
            of tComma:
                case level.mode
                of mFlowSequenceItem:
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                    state = ypFlow
                of mFlowMapValue:
                    level.mode = mFlowMapKey
                    ancestry.add(level)
                    level = DocumentLevel(mode: mUnknown, indicatorColumn: -1,
                                          indentationColumn: -1)
                    state = ypFlow
                else:
                    yieldUnexpectedToken()
            of tClosingBrace:
                if level.mode != mFlowMapValue:
                    yieldUnexpectedToken()
                else:
                    yield YamlStreamEvent(kind: yamlEndMap)
                    if ancestry.len > 0:
                        level = ancestry.pop()
                        case level.mode
                        of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                            state = ypFlowAfterObject
                        else:
                            state = ypBlockLineEnd
                    else:
                        state = ypExpectingDocumentEnd
            of tClosingBracket:
                if level.mode != mFlowSequenceItem:
                    yieldUnexpectedToken()
                else:
                    yield YamlStreamEvent(kind: yamlEndSequence)
                    if ancestry.len > 0:
                        level = ancestry.pop()
                        case level.mode
                        of mFlowMapKey, mFlowMapValue, mFlowSequenceItem:
                            state = ypFlowAfterObject
                        else:
                            state = ypBlockLineEnd
                    else:
                        state = ypExpectingDocumentEnd
            else:
                yieldUnexpectedToken()
        of ypExpectingDocumentEnd:
            case token
            of tComment, tLineStart:
                discard
            of tStreamEnd, tDocumentEnd:
                yieldDocumentEnd()
                state = ypInitial
            of tDirectivesEnd:
                yieldDocumentEnd()
                state = ypAfterDirectivesEnd
                continue
            else:
                yieldUnexpectedToken("document end")
        token = nextToken(lex)