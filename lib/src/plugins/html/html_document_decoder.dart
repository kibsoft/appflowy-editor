import 'dart:collection';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parse;

typedef ElementParser = Iterable<Node> Function(
  dom.Element element,
  (Delta, Iterable<Node>) Function(
    dom.Element element, {
    String? type,
  }) parseDeltaElement,
);

class DocumentHTMLDecoder extends Converter<String, Document> {
  DocumentHTMLDecoder({
    this.customDecoders = const {},
  });

  final Map<String, ElementParser> customDecoders;
  // Set to true to enable parsing color from HTML
  static bool enableColorParse = true;

  /// Block-level tags that prevent a div from being "simple" (inline-only).
  static const _blockTags = {
    'div', 'p', 'table', 'ul', 'ol', 'blockquote', 'section',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  };

  /// Returns true if [element] is a div that contains only inline content.
  bool _isSimpleDiv(dom.Element element) {
    if (element.localName?.toLowerCase() != 'div') return false;
    for (final child in element.children) {
      if (_blockTags.contains(child.localName?.toLowerCase())) {
        return false;
      }
    }
    return true;
  }

  /// Returns true when consecutive divs [div1] and [div2] should be merged.
  /// Email clients (Outlook, Word) use <div>line1</div><div>line2</div> for
  /// line breaks within one logical paragraph.
  bool _shouldMergeConsecutiveDivs(dom.Element div1, dom.Element div2) {
    if (!_isSimpleDiv(div1) || !_isSimpleDiv(div2)) return false;
    final t1 = div1.text.trim();
    final t2 = div2.text.trim();
    if (t1.isEmpty || t2.isEmpty) return false;
    // Merge list items: div2 starts with same prefix as div1 (e.g. "Plan A" + "Plan B")
    final firstWord = t1.split(RegExp(r'\s+')).firstOrNull;
    if (firstWord != null &&
        firstWord.length >= 2 &&
        t2.startsWith(firstWord)) {
      return true;
    }
    // Merge postscript continuation: div2 starts with "X.Y.Z." (e.g. P.P.S., N.B.)
    if (RegExp(r'^[A-Za-z]\.[A-Za-z]\.[A-Za-z]\.').hasMatch(t2)) return true;
    return false;
  }

  /// Returns true when div1 (simple, ends with ?) and div2 (has text + nested block)
  /// should be merged. Email clients often split question + instruction into
  /// separate divs where div2 contains both text and a nested block (e.g. signature).
  bool _shouldMergeWithDivContainingBlock(dom.Element div1, dom.Element div2) {
    if (div1.localName?.toLowerCase() != 'div' || div2.localName?.toLowerCase() != 'div') {
      return false;
    }
    if (!_isSimpleDiv(div1)) return false;
    if (div2.children.isEmpty) return false;
    final firstBlock = div2.children.firstWhere(
      (c) => c is dom.Element && _blockTags.contains((c as dom.Element).localName?.toLowerCase()),
      orElse: () => div2,
    );
    if (firstBlock == div2) return false;
    final t1 = div1.text.trim();
    if (t1.isEmpty || !t1.endsWith('?')) return false;
    final textBeforeBlock = div2.nodes
        .takeWhile((n) => n != firstBlock)
        .map((n) => n is dom.Text ? n.text : (n is dom.Element && n.localName == 'br' ? '\n' : ''))
        .join()
        .trim();
    return textBeforeBlock.isNotEmpty;
  }

  /// Merges div1 (simple) with the text part of div2 (text + nested block).
  /// Replaces div1 with merged div, replaces div2 with just its block children.
  void _mergeSimpleWithDivContainingBlock(
    dom.Element parent,
    dom.Element div1,
    dom.Element div2,
  ) {
    final firstBlockIndex = div2.nodes.toList().indexWhere(
          (n) => n is dom.Element && _blockTags.contains((n as dom.Element).localName?.toLowerCase()),
        );
    if (firstBlockIndex < 0) return;

    final merged = dom.Element.tag('div');
    for (final node in div1.nodes) {
      merged.append(node.clone(true));
    }
    merged.append(dom.Element.tag('br'));
    var textEnd = firstBlockIndex;
    while (textEnd > 0) {
      final n = div2.nodes.elementAt(textEnd - 1);
      if (n is dom.Element && n.localName == 'br') {
        textEnd--;
      } else {
        break;
      }
    }
    for (var i = 0; i < textEnd; i++) {
      final n = div2.nodes.elementAt(i);
      merged.append(n.clone(true));
    }

    div1.remove();
    final blockChildren = div2.nodes.toList().skip(firstBlockIndex).whereType<dom.Element>().toList();
    if (blockChildren.length == 1) {
      parent.insertBefore(merged, div2);
      div2.replaceWith(blockChildren.first);
    } else {
      parent.insertBefore(merged, div2);
      for (final block in blockChildren) {
        block.remove();
        parent.insertBefore(block, div2);
      }
      div2.remove();
    }
  }

  /// Merges consecutive simple divs in [element]'s children so they become
  /// one div with <br /> between. Modifies DOM in place.
  void _mergeConsecutiveSimpleDivs(dom.Element element) {
    for (final child in element.children.toList()) {
      if (child is dom.Element) {
        _mergeConsecutiveSimpleDivs(child);
      }
    }

    // Merge "question div" + "div with text + nested block" (e.g. instruction + signature)
    var children = element.children.toList();
    var i = 0;
    while (i < children.length - 1) {
      final div1 = children[i];
      final div2 = children[i + 1];
      if (div1 is dom.Element &&
          div2 is dom.Element &&
          _shouldMergeWithDivContainingBlock(div1, div2)) {
        _mergeSimpleWithDivContainingBlock(element, div1, div2);
        children = element.children.toList();
        continue;
      }
      i++;
    }

    children = element.children.toList();
    i = 0;
    while (i < children.length) {
      final child = children[i];
      if (child is! dom.Element || child.localName?.toLowerCase() != 'div') {
        i++;
        continue;
      }

      var runEnd = i + 1;
      while (runEnd < children.length) {
        final prev = children[runEnd - 1];
        final c = children[runEnd];
        if (c is! dom.Element ||
            c.localName?.toLowerCase() != 'div' ||
            !_shouldMergeConsecutiveDivs(prev as dom.Element, c)) {
          break;
        }
        runEnd++;
      }

      if (runEnd - i > 1) {
        final merged = dom.Element.tag('div');
        for (var j = i; j < runEnd; j++) {
          if (j > i) {
            merged.append(dom.Element.tag('br'));
          }
          final div = children[j];
          for (final node in div.nodes) {
            merged.append(node.clone(true));
          }
        }
        final ref = runEnd < children.length ? children[runEnd] : null;
        for (var j = runEnd - 1; j >= i; j--) {
          children[j].remove();
        }
        element.insertBefore(merged, ref);
      }
      i = runEnd;
    }
  }

  @override
  Document convert(String input) {
    final document = parse(input);
    final body = document.body;
    if (body == null) {
      return Document.blank(withInitialText: false);
    }

    // Merge consecutive simple divs (email clients use <div>line1</div><div>line2</div>)
    _mergeConsecutiveSimpleDivs(body);

    ///This is used for temporarily handling documents copied from Google Docs,
    /// see [#6808](https://github.com/AppFlowy-IO/AppFlowy/issues/6808).
    /// It can prevent parsing exceptions caused by having a single,
    /// all-encompassing tag under the body. However,
    /// this method needs to be removed in the future as it is not stable
    final parseForSingleChild = body.children.length == 1 &&
        HTMLTags.formattingElements.contains(body.children.first.localName);

    return Document.blank(withInitialText: false)
      ..insert(
        [0],
        parseForSingleChild
            ? _parseElement(body.children.first.children)
            : _parseElement(body.nodes),
      );
  }

  /// Extracts text from a DOM node, inserting newlines for br elements.
  String _getTextWithNewlines(dom.Node node) {
    if (node is dom.Element) {
      if (node.localName == HTMLTags.br) return '\n';
      return node.nodes.map(_getTextWithNewlines).join();
    }
    if (node is dom.Text) return node.text;
    return '';
  }

  Iterable<Node> _parseElement(
    Iterable<dom.Node> domNodes, {
    String? type,
  }) {
    var delta = Delta();
    final List<Node> nodes = [];
    for (final domNode in domNodes) {
      if (domNode is dom.Element) {
        final localName = domNode.localName;
        if (HTMLTags.formattingElements.contains(localName)) {
          final style = domNode.attributes['style'];

          ///This is used for temporarily handling documents copied from Google Docs,
          /// see [#6808](https://github.com/AppFlowy-IO/AppFlowy/issues/6808).
          final isMeaninglessTag = style == 'font-weight:normal;' && localName == HTMLTags.bold;
          if (isMeaninglessTag && domNode.children.isNotEmpty) {
            nodes.addAll(_parseElement(domNode.children));
          } else {
            final attributes = _parserFormattingElementAttributes(domNode);
            final text = _getTextWithNewlines(domNode);
            delta.insert(text, attributes: attributes);
          }
        } else if (localName == HTMLTags.br) {
          delta.insert('\n');
        } else if (HTMLTags.specialElements.contains(localName)) {
          if (delta.isNotEmpty) {
            nodes.add(
                delta.toPlainText().trim().isEmpty ? paragraphNode() : paragraphNode(delta: delta));
            delta = Delta();
          }
          nodes.addAll(
            _parseSpecialElements(
              domNode,
              type: type ?? ParagraphBlockKeys.type,
            ),
          );
        } else if (customDecoders.containsKey(localName)) {
          if (delta.isNotEmpty) {
            nodes.add(
                delta.toPlainText().trim().isEmpty ? paragraphNode() : paragraphNode(delta: delta));
            delta = Delta();
          }
          nodes.addAll(
            customDecoders[localName]!(domNode, _parseDeltaElement),
          );
        }
      } else if (domNode is dom.Text) {
        // skip the empty text node
        if (domNode.text.trim().isEmpty) {
          continue;
        }
        delta.insert(domNode.text);
      } else {
        AppFlowyEditorLog.editor.debug('Unknown node type: $domNode');
      }
    }
    if (delta.isNotEmpty) {
      nodes.add(delta.toPlainText().trim().isEmpty ? paragraphNode() : paragraphNode(delta: delta));
    }

    return nodes;
  }

  Iterable<Node> _parseSpecialElements(
    dom.Element element, {
    required String type,
  }) {
    final localName = element.localName;
    switch (localName) {
      case HTMLTags.h1:
        return _parseHeadingElement(element, level: 1);

      case HTMLTags.h2:
        return _parseHeadingElement(element, level: 2);

      case HTMLTags.h3:
        return _parseHeadingElement(element, level: 3);

      case HTMLTags.h4:
        return _parseHeadingElement(element, level: 4);

      case HTMLTags.h5:
        return _parseHeadingElement(element, level: 5);

      case HTMLTags.h6:
        return _parseHeadingElement(element, level: 6);

      case HTMLTags.unorderedList:
        return _parseUnOrderListElement(element);

      case HTMLTags.orderedList:
        return _parseOrderListElement(element);

      case HTMLTags.table:
        return _parseTable(element);

      case HTMLTags.list:
        return [
          _parseListElement(
            element,
            type: type,
          ),
        ];

      case HTMLTags.paragraph:
        return _parseParagraphElement(element);

      case HTMLTags.blockQuote:
        return [_parseBlockQuoteElement(element)];

      case HTMLTags.image:
        return [_parseImageElement(element)];

      default:
        return _parseParagraphElement(element);
    }
  }

  Iterable<Node> _parseTable(dom.Element element) {
    final List<Node> tablenodes = [];
    int columnLenth = 0;
    int rowLength = 0;
    for (final data in element.children) {
      final (col, row, rwdata) = _parsetableRows(data);
      columnLenth = columnLenth + col;
      rowLength = rowLength + row;

      tablenodes.addAll(rwdata);
    }

    return [
      TableNode(
        node: Node(
          type: TableBlockKeys.type,
          attributes: {
            TableBlockKeys.rowsLen: rowLength,
            TableBlockKeys.colsLen: columnLenth,
            TableBlockKeys.colDefaultWidth: TableDefaults.colWidth,
            TableBlockKeys.rowDefaultHeight: TableDefaults.rowHeight,
            TableBlockKeys.colMinimumWidth: TableDefaults.colMinimumWidth,
          },
          children: tablenodes,
        ),
      ).node,
    ];
  }

  (int, int, List<Node>) _parsetableRows(dom.Element element) {
    final List<Node> nodes = [];
    int colLength = 0;
    int rowLength = 0;

    for (final data in element.children) {
      final tabledata = _parsetableData(data, rowPosition: rowLength);
      if (colLength == 0) {
        colLength = tabledata.length;
      }
      nodes.addAll(tabledata);
      rowLength++;
    }

    return (colLength, rowLength, nodes);
  }

  Iterable<Node> _parsetableData(
    dom.Element element, {
    required int rowPosition,
  }) {
    final List<Node> nodes = [];
    int columnPosition = 0;

    for (final data in element.children) {
      Attributes attributes = {
        TableCellBlockKeys.colPosition: columnPosition,
        TableCellBlockKeys.rowPosition: rowPosition,
      };
      if (data.attributes.isNotEmpty) {
        final deltaAttributes = _getDeltaAttributesFromHTMLAttributes(
              element.attributes,
            ) ??
            {};
        attributes.addAll(deltaAttributes);
      }

      List<Node> children;
      if (data.children.isEmpty) {
        children = [paragraphNode(text: data.text)];
      } else {
        children = _parseTableSpecialNodes(data).toList();
      }

      final node = Node(
        type: TableCellBlockKeys.type,
        attributes: attributes,
        children: children,
      );

      nodes.add(node);
      columnPosition++;
    }

    return nodes;
  }

  Iterable<Node> _parseTableSpecialNodes(dom.Element element) {
    final List<Node> nodes = [];

    if (element.children.isNotEmpty) {
      for (final childrens in element.children) {
        nodes.addAll(_parseTableDataElementsData(childrens));
      }
    } else {
      nodes.addAll(_parseTableDataElementsData(element));
    }

    return nodes;
  }

  List<Node> _parseTableDataElementsData(dom.Element element) {
    final List<Node> nodes = [];
    final delta = Delta();
    final localName = element.localName;

    if (HTMLTags.formattingElements.contains(localName)) {
      final attributes = _parserFormattingElementAttributes(element);
      delta.insert(element.text, attributes: attributes);
    } else if (HTMLTags.specialElements.contains(localName)) {
      if (delta.isNotEmpty) {
        nodes.add(paragraphNode(delta: delta));
      }
      nodes.addAll(
        _parseSpecialElements(
          element,
          type: ParagraphBlockKeys.type,
        ),
      );
    } else if (element is dom.Text) {
      // skip the empty text node

      delta.insert(element.text);
    }

    if (delta.isNotEmpty) {
      nodes.add(paragraphNode(delta: delta));
    }

    return nodes;
  }

  Attributes _parserFormattingElementAttributes(
    dom.Element element,
  ) {
    final localName = element.localName;

    Attributes attributes = {};
    switch (localName) {
      case HTMLTags.bold || HTMLTags.strong:
        attributes = {AppFlowyRichTextKeys.bold: true};
        break;

      case HTMLTags.italic || HTMLTags.em:
        attributes = {AppFlowyRichTextKeys.italic: true};
        break;

      case HTMLTags.underline:
        attributes = {AppFlowyRichTextKeys.underline: true};
        break;

      case HTMLTags.del:
        attributes = {AppFlowyRichTextKeys.strikethrough: true};
        break;

      case HTMLTags.code:
        attributes = {AppFlowyRichTextKeys.code: true};

      case HTMLTags.span || HTMLTags.mark:
        final deltaAttributes = _getDeltaAttributesFromHTMLAttributes(
              element.attributes,
            ) ??
            {};
        attributes.addAll(deltaAttributes);
        break;

      case HTMLTags.anchor:
        final href = element.attributes['href'];
        if (href != null) {
          attributes = {AppFlowyRichTextKeys.href: href};
        }
        break;

      case HTMLTags.strikethrough:
        attributes = {AppFlowyRichTextKeys.strikethrough: true};
        break;

      default:
        break;
    }
    for (final child in element.children) {
      attributes.addAll(_parserFormattingElementAttributes(child));
    }

    return attributes;
  }

  Iterable<Node> _parseHeadingElement(
    dom.Element element, {
    required int level,
  }) {
    final (delta, specialNodes) = _parseDeltaElement(element);

    return [
      headingNode(
        level: level,
        delta: delta,
      ),
      ...specialNodes,
    ];
  }

  Node _parseBlockQuoteElement(dom.Element element) {
    final (delta, nodes) = _parseDeltaElement(element);

    return quoteNode(
      delta: delta,
      children: nodes,
    );
  }

  Iterable<Node> _parseUnOrderListElement(dom.Element element) {
    return element.children
        .map(
          (child) => _parseListElement(child, type: BulletedListBlockKeys.type),
        )
        .toList();
  }

  Iterable<Node> _parseOrderListElement(dom.Element element) {
    return element.children
        .map(
          (child) => _parseListElement(child, type: NumberedListBlockKeys.type),
        )
        .toList();
  }

  Node _parseListElement(
    dom.Element element, {
    required String type,
  }) {
    var (delta, node) = _parseDeltaElement(element, type: type);
    if (delta.isEmpty &&
        element.children.length == 1 &&
        element.children.first.localName == HTMLTags.paragraph) {
      (delta, node) = _parseDeltaElement(element.children.first, type: type);
    } else if (delta.isEmpty &&
        element.children.isNotEmpty &&
        element.children.first.localName == HTMLTags.paragraph) {
      final paragraphElement = element.children.first;
      (delta, _) = _parseDeltaElement(paragraphElement, type: type);

      final remainingChildren = element.children.skip(1);
      node = remainingChildren.expand((child) {
        if (HTMLTags.specialElements.contains(child.localName)) {
          return _parseSpecialElements(child, type: type);
        }

        return <Node>[];
      }).toList();
    }

    return Node(
      type: type,
      children: node,
      attributes: {ParagraphBlockKeys.delta: delta.toJson()},
    );
  }

  Iterable<Node> _parseParagraphElement(dom.Element element) {
    final (delta, specialNodes) = _parseDeltaElement(element);
    if (delta.isEmpty && specialNodes.isNotEmpty) {
      return specialNodes;
    }
    // Div with only <br /> produces delta "\n" — use empty paragraph to avoid double line break
    if (delta.length == 1 && delta.toPlainText() == '\n' && specialNodes.isEmpty) {
      return [paragraphNode()];
    }
    return [paragraphNode(delta: delta), ...specialNodes];
  }

  Node _parseImageElement(dom.Element element) {
    final src = element.attributes['src'];
    if (src == null || src.isEmpty || !src.startsWith('http')) {
      return paragraphNode(); // return empty paragraph
    }
    // only support network image
    return imageNode(
      url: src,
    );
  }

  (Delta, Iterable<Node>) _parseDeltaElement(
    dom.Element element, {
    String? type,
  }) {
    final delta = Delta();
    final nodes = <Node>[];
    final children = element.nodes.toList();

    for (final child in children) {
      if (child is dom.Element) {
        if (child.localName == HTMLTags.br) {
          delta.insert('\n');
        } else if (child.children.isNotEmpty &&
            HTMLTags.formattingElements.contains(child.localName) == false &&
            HTMLTags.specialElements.contains(child.localName) == false) {
          //rich editor for webs do this so handling that case for href  <a href="https://www.google.com" rel="noopener noreferrer" target="_blank"><strong><em><u>demo</u></em></strong></a>

          nodes.addAll(_parseElement(child.children, type: type));
        } else {
          if (HTMLTags.specialElements.contains(child.localName)) {
            nodes.addAll(
              _parseSpecialElements(
                child,
                type: ParagraphBlockKeys.type,
              ),
            );
          } else if (customDecoders.containsKey(child.localName)) {
            nodes.addAll(
              customDecoders[child.localName]!(child, _parseDeltaElement),
            );
          } else {
            final attributes = _parserFormattingElementAttributes(child);
            final text = _getTextWithNewlines(child);
            delta.insert(text, attributes: attributes);
          }
        }
      } else {
        delta.insert(child.text?.replaceAll(RegExp(r'\n+$'), '') ?? '');
      }
    }

    return (delta, nodes);
  }

  Attributes? _getDeltaAttributesFromHTMLAttributes(
    LinkedHashMap<Object, String> htmlAttributes,
  ) {
    final Attributes attributes = {};
    final style = htmlAttributes['style'];
    final css = _getCssFromString(style);

    // font weight
    final fontWeight = css['font-weight'];
    if (fontWeight != null) {
      if (fontWeight == 'bold') {
        attributes[AppFlowyRichTextKeys.bold] = true;
      } else {
        final weight = int.tryParse(fontWeight);
        if (weight != null && weight >= 500) {
          attributes[AppFlowyRichTextKeys.bold] = true;
        }
      }
    }

    // decoration
    final textDecoration = css['text-decoration'];
    if (textDecoration != null) {
      final decorations = textDecoration.split(' ');
      for (final decoration in decorations) {
        switch (decoration) {
          case 'underline':
            attributes[AppFlowyRichTextKeys.underline] = true;
            break;

          case 'line-through':
            attributes[AppFlowyRichTextKeys.strikethrough] = true;
            break;

          default:
            break;
        }
      }
    }

    // background color
    final backgroundColor = css['background-color'];
    if (enableColorParse && backgroundColor != null) {
      final highlightColor = backgroundColor.tryToColor()?.toHex();
      if (highlightColor != null) {
        attributes[AppFlowyRichTextKeys.backgroundColor] = highlightColor;
      }
    }

    // background
    final background = css['background'];
    if (enableColorParse && background != null) {
      final highlightColor = background.tryToColor()?.toHex();
      if (highlightColor != null) {
        attributes[AppFlowyRichTextKeys.backgroundColor] = highlightColor;
      }
    }

    // color
    final color = css['color'];
    if (enableColorParse && color != null) {
      final textColor = color.tryToColor()?.toHex();
      if (textColor != null) {
        attributes[AppFlowyRichTextKeys.textColor] = textColor;
      }
    }

    // italic
    final fontStyle = css['font-style'];
    if (fontStyle == 'italic') {
      attributes[AppFlowyRichTextKeys.italic] = true;
    }

    return attributes.isEmpty ? null : attributes;
  }

  Map<String, String> _getCssFromString(String? cssString) {
    final Map<String, String> result = {};
    if (cssString == null) {
      return result;
    }
    final entries = cssString.split(';');
    for (final entry in entries) {
      final tuples = entry.split(':');
      if (tuples.length < 2) {
        continue;
      }
      result[tuples[0].trim()] = tuples[1].trim();
    }

    return result;
  }
}

class HTMLTags {
  static const h1 = 'h1';
  static const h2 = 'h2';
  static const h3 = 'h3';
  static const h4 = 'h4';
  static const h5 = 'h5';
  static const h6 = 'h6';
  static const orderedList = 'ol';
  static const unorderedList = 'ul';
  static const list = 'li';
  static const paragraph = 'p';
  static const image = 'img';
  static const anchor = 'a';
  static const italic = 'i';
  static const em = 'em';
  static const bold = 'b';
  static const underline = 'u';
  static const strikethrough = 's';
  static const del = 'del';
  static const strong = 'strong';
  static const checkbox = 'input';
  static const br = 'br';
  static const span = 'span';
  static const code = 'code';
  static const blockQuote = 'blockquote';
  static const div = 'div';
  static const divider = 'hr';
  static const table = 'table';
  static const tableRow = 'tr';
  static const tableheader = "th";
  static const tabledata = "td";
  static const section = 'section';
  static const font = 'font';
  static const mark = 'mark';

  static List<String> formattingElements = [
    HTMLTags.anchor,
    HTMLTags.italic,
    HTMLTags.em,
    HTMLTags.bold,
    HTMLTags.underline,
    HTMLTags.del,
    HTMLTags.strong,
    HTMLTags.span,
    HTMLTags.code,
    HTMLTags.strikethrough,
    HTMLTags.font,
    HTMLTags.mark,
  ];

  static List<String> specialElements = [
    HTMLTags.h1,
    HTMLTags.h2,
    HTMLTags.h3,
    HTMLTags.h4,
    HTMLTags.h5,
    HTMLTags.h6,
    HTMLTags.unorderedList,
    HTMLTags.orderedList,
    HTMLTags.div,
    HTMLTags.list,
    HTMLTags.table,
    HTMLTags.paragraph,
    HTMLTags.blockQuote,
    HTMLTags.checkbox,
    HTMLTags.image,
    HTMLTags.section,
  ];

  static bool isTopLevel(String tag) {
    return tag == h1 ||
        tag == h2 ||
        tag == h3 ||
        tag == table ||
        tag == checkbox ||
        tag == paragraph ||
        tag == div ||
        tag == blockQuote;
  }
}
