/**
 * GDScript syntax highlighting (Godot 4 colors)
 * Uses a tokenizer approach to avoid regex conflicts
 */

const GD_KEYWORDS = new Set([
  'var', 'func', 'signal', 'class_name', 'extends', 'class', 'enum', 'const',
  'if', 'elif', 'else', 'for', 'while', 'match', 'break', 'continue', 'pass', 'return',
  'and', 'or', 'not', 'in', 'is', 'as', 'self', 'super', 'true', 'false', 'null',
  'void', 'await', 'yield', 'static', 'preload', 'load'
]);

const GD_TYPES = new Set([
  'int', 'float', 'bool', 'String', 'Vector2', 'Vector3', 'Vector4',
  'Color', 'Array', 'Dictionary', 'Object', 'Node', 'Node2D', 'Node3D',
  'Control', 'Resource', 'Variant', 'void'
]);

export function highlightGDScript(code) {
  const tokens = [];
  let i = 0;

  while (i < code.length) {
    const ch = code[i];
    const rest = code.slice(i);

    // Comments
    if (ch === '#') {
      const end = code.indexOf('\n', i);
      const comment = end === -1 ? code.slice(i) : code.slice(i, end);
      tokens.push({ type: 'comment', text: comment });
      i += comment.length;
      continue;
    }

    // Strings
    if (ch === '"' || ch === "'") {
      let j = i + 1;
      while (j < code.length && code[j] !== ch) {
        if (code[j] === '\\') j++; // skip escaped char
        j++;
      }
      const str = code.slice(i, j + 1);
      tokens.push({ type: 'string', text: str });
      i = j + 1;
      continue;
    }

    // Annotations (@export, @onready, etc.)
    if (ch === '@') {
      const match = rest.match(/^@\w+/);
      if (match) {
        tokens.push({ type: 'annotation', text: match[0] });
        i += match[0].length;
        continue;
      }
    }

    // Arrow ->
    if (rest.startsWith('->')) {
      tokens.push({ type: 'arrow', text: '->' });
      i += 2;
      continue;
    }

    // Numbers
    if (/\d/.test(ch)) {
      const match = rest.match(/^\d+\.?\d*/);
      if (match) {
        tokens.push({ type: 'number', text: match[0] });
        i += match[0].length;
        continue;
      }
    }

    // Words (identifiers, keywords, types, function calls)
    if (/[a-zA-Z_]/.test(ch)) {
      const match = rest.match(/^[a-zA-Z_]\w*/);
      if (match) {
        const word = match[0];
        const afterWord = code.slice(i + word.length);
        const isCallable = /^\s*\(/.test(afterWord); // followed by (

        let type = 'identifier'; // default: white for variables
        if (GD_KEYWORDS.has(word)) type = 'keyword';
        else if (GD_TYPES.has(word) || /^[A-Z]/.test(word)) type = 'type';
        else if (isCallable) type = 'function'; // function/method calls

        tokens.push({ type, text: word });
        i += word.length;
        continue;
      }
    }

    // Everything else (operators, punctuation, whitespace)
    tokens.push({ type: 'plain', text: ch });
    i++;
  }

  // Convert tokens to HTML with Godot-like colors
  return tokens.map(t => {
    const escaped = t.text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    switch (t.type) {
      case 'keyword': return `<span style="color:#FF7085">${escaped}</span>`; // Pink/red
      case 'type': return `<span style="color:#8EFFDA">${escaped}</span>`; // Teal/mint
      case 'function': return `<span style="color:#66E6FF">${escaped}</span>`; // Cyan (function calls)
      case 'string': return `<span style="color:#FFE566">${escaped}</span>`; // Yellow
      case 'number': return `<span style="color:#A3FFB4">${escaped}</span>`; // Green
      case 'comment': return `<span style="color:#9A9EA6">${escaped}</span>`; // Gray
      case 'annotation': return `<span style="color:#FFB373">${escaped}</span>`; // Orange
      case 'arrow': return `<span style="color:#ABC8FF">${escaped}</span>`; // Light blue
      case 'identifier': return `<span style="color:#CDCFD2">${escaped}</span>`; // White/light gray (variables)
      default: return escaped;
    }
  }).join('');
}
