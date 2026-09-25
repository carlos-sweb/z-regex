// Evaluated inside each test's realm (a fresh vm context) before the
// harness. Replaces RegExp.prototype.exec with an implementation of
// RegExpBuiltinExec (ECMA-262 §22.2.7.2) whose matching is done by zregex.
//
// Every RegExp method that matches (test, @@match, @@matchAll, @@replace,
// @@search, @@split) reaches the matcher through RegExpExec, which calls a
// callable `exec` property, so all matching in the realm goes to zregex
// while V8 still supplies the language and the surrounding algorithms.
//
// The outer process provides `__zregexBridge(source, flags, S, lastIndex,
// sticky)`; this script captures it and removes the global.
(function () {
  'use strict';
  const bridge = globalThis.__zregexBridge;
  delete globalThis.__zregexBridge;

  const proto = RegExp.prototype;
  // The built-in getters read the [[OriginalSource]]/[[OriginalFlags]]
  // internal slots directly, so calling the saved originals is not
  // observable through user-defined overrides (unlike reading `R.flags`).
  const getter = (name) => Object.getOwnPropertyDescriptor(proto, name).get;
  const get = {
    source: getter('source'),
    global: getter('global'),
    ignoreCase: getter('ignoreCase'),
    multiline: getter('multiline'),
    dotAll: getter('dotAll'),
    unicode: getter('unicode'),
    unicodeSets: getter('unicodeSets'),
    sticky: getter('sticky'),
    hasIndices: getter('hasIndices'),
  };
  const call = Function.prototype.call.bind(Function.prototype.call);
  const ArrayCtor = Array;
  const ObjectCreate = Object.create;
  const defineProperty = Object.defineProperty;
  const TypeErrorCtor = TypeError;
  const StringCtor = String;
  const MathMin = Math.min;
  const MathMax = Math.max;
  const MathFloor = Math.floor;
  const NumberCtor = Number;

  function toLength(value) {
    let n = NumberCtor(value);
    if (n !== n || n <= 0) return 0;
    if (n === Infinity) return 2 ** 53 - 1;
    n = MathFloor(n);
    return MathMin(n, 2 ** 53 - 1);
  }

  function createDataProperty(obj, key, value) {
    defineProperty(obj, key, { value, writable: true, enumerable: true, configurable: true });
  }

  function flagsOf(R) {
    let f = '';
    if (call(get.hasIndices, R)) f += 'd';
    if (call(get.global, R)) f += 'g';
    if (call(get.ignoreCase, R)) f += 'i';
    if (call(get.multiline, R)) f += 'm';
    if (call(get.dotAll, R)) f += 's';
    if (call(get.unicode, R)) f += 'u';
    if (get.unicodeSets && call(get.unicodeSets, R)) f += 'v';
    if (call(get.sticky, R)) f += 'y';
    return f;
  }

  function exec(string) {
    const R = this;
    if (R === null || (typeof R !== 'object' && typeof R !== 'function')) {
      throw new TypeErrorCtor('RegExp.prototype.exec called on incompatible receiver');
    }
    // Throws a TypeError for non-RegExp receivers, like [[RegExpMatcher]].
    const source = call(get.source, R);
    const S = StringCtor(string);
    return builtinExec(R, S, source, flagsOf(R));
  }

  function builtinExec(R, S, source, flags) {
    const length = S.length;
    let lastIndex = toLength(R.lastIndex);
    const global = flags.includes('g');
    const sticky = flags.includes('y');
    const hasIndices = flags.includes('d');
    if (!global && !sticky) lastIndex = 0;
    if (lastIndex > length) {
      if (global || sticky) R.lastIndex = 0;
      return null;
    }
    // `source` of an empty pattern is "(?:)", which zregex compiles to the
    // same empty match.
    const r = bridge(source, flags, S, lastIndex, sticky);
    if (r === null) {
      if (global || sticky) R.lastIndex = 0;
      return null;
    }
    const caps = r.captures;
    const matchStart = caps[0];
    const e = caps[1];
    if (global || sticky) R.lastIndex = e;

    const n = (caps.length >> 1) - 1;
    const A = new ArrayCtor(n + 1);
    createDataProperty(A, 'index', matchStart);
    createDataProperty(A, 'input', S);
    createDataProperty(A, '0', S.slice(matchStart, e));

    const names = r.names;
    const hasGroups = names.length > 0;
    const groups = hasGroups ? ObjectCreate(null) : undefined;
    createDataProperty(A, 'groups', groups);

    let indices;
    let indicesGroups;
    if (hasIndices) {
      indices = new ArrayCtor(n + 1);
      indicesGroups = hasGroups ? ObjectCreate(null) : undefined;
      createDataProperty(indices, '0', [matchStart, e]);
    }
    for (let i = 1; i <= n; i++) {
      const s = caps[2 * i];
      const end = caps[2 * i + 1];
      const value = s < 0 ? undefined : S.slice(s, end);
      createDataProperty(A, StringCtor(i), value);
      if (hasIndices) createDataProperty(indices, StringCtor(i), s < 0 ? undefined : [s, end]);
    }
    if (hasGroups) {
      // Duplicate names: the value is the participating group's, else undefined.
      for (let k = 0; k < names.length; k++) {
        const name = names[k][0];
        const idx = names[k][1];
        const s = caps[2 * idx];
        const matched = s >= 0;
        if (matched || !(name in groups)) {
          createDataProperty(groups, name, matched ? S.slice(s, caps[2 * idx + 1]) : undefined);
          if (hasIndices) {
            createDataProperty(indicesGroups, name, matched ? [s, caps[2 * idx + 1]] : undefined);
          }
        }
      }
    }
    if (hasIndices) {
      createDataProperty(indices, 'groups', indicesGroups);
      createDataProperty(A, 'indices', indices);
    }
    return A;
  }

  // Same attributes as the built-in, and the same name/length.
  const desc = Object.getOwnPropertyDescriptor(proto, 'exec');
  const replacement = { exec(string) { return call(exec, this, string); } }.exec;
  defineProperty(replacement, 'name', { value: 'exec', configurable: true });
  defineProperty(proto, 'exec', { ...desc, value: replacement });
})();
