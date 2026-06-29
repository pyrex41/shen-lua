// GENERATED — do not edit. Built by examples/openresty/scripts/build-client.{sh,mjs}
// from rules.shen (+ client.glue.shen) via Ratatoskr (Shen tree-shaker) and
// ShenScript's compiler. Regenerate with: examples/openresty/scripts/build-client.sh
// kernel defuns: 99; user: client-prog.kl; needs-eval: false
// Self-contained: runtime.js + overrides.js are embedded; no imports, no checkout needed at runtime.
// The KLambda runtime: everything compiled kernel/user code references on $,
// with no compiler. This module deliberately has ZERO imports and a single
// default export so build tools (bin/ratatoskr-build.js) can embed its source
// verbatim by replacing "export default" with a const declaration.
// eval-kl raises unless a compiler layer (lib/backend.js) is attached.

const runtime = (options = {}) => {
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

  class Cons {
    constructor(head, tail) {
      this.head = head;
      this.tail = tail;
    }
  }

  class Trampoline {
    constructor(f, args) {
      this.f = f;
      this.args = args;
    }
  }

  class Cell {
    constructor(name) {
      this.name = name;
      this.f = () => raise(`function "${name}" is not defined`);
      this.value = undefined;
      this.valueExists = false;
    }
    set(x) {
      this.value = x;
      this.valueExists = true;
      return x;
    }
    get() {
      return this.valueExists ? this.value : raise(`global "${this.name}" is not defined`);
    }
  }

  const raise = x => { throw new Error(x); };
  const s = (x, y) => Symbol.for(String.raw(x, y));
  const produceState = (proceed, select, next, state, result = []) => {
    for (; proceed(state); state = next(state)) {
      result.push(select(state));
    }
    return { result, state };
  };
  const produce = (proceed, select, next, state, result = []) =>
    produceState(proceed, select, next, state, result).result;

  const nameOf     = Symbol.keyFor;
  const symbolOf   = Symbol.for;
  const shenTrue   = s`true`;
  const shenFalse  = s`false`;
  const isObject   = x => !Array.isArray(x) && typeof x === 'object' && x !== null;
  const isNumber   = x => typeof x === 'number' && Number.isFinite(x);
  const isNzNumber = x => isNumber(x) && x !== 0;
  const isString   = x => typeof x === 'string' || x instanceof String;
  const isNeString = x => isString(x) && x.length > 0;
  const isSymbol   = x => typeof x === 'symbol';
  const isFunction = x => typeof x === 'function';
  const isArray    = x => Array.isArray(x);
  const isEArray   = x => isArray(x) && x.length === 0;
  const isNeArray  = x => isArray(x) && x.length > 0;
  const isError    = x => x instanceof Error;
  const isCons     = x => x instanceof Cons;
  const isList     = x => x === null || isCons(x);
  const asNumber   = x => isNumber(x)   ? x : raise('number expected');
  const asNzNumber = x => isNzNumber(x) ? x : raise('non-zero number expected');
  const asString   = x => isString(x)   ? x : raise('string expected');
  const asNeString = x => isNeString(x) ? x : raise('non-empty string expected');
  const asSymbol   = x => isSymbol(x)   ? x : raise('symbol expected');
  const asFunction = x => isFunction(x) ? x : raise('function expected');
  const asArray    = x => isArray(x)    ? x : raise('array expected');
  const asCons     = x => isCons(x)     ? x : raise('cons expected');
  const asList     = x => isList(x)     ? x : raise('list expected');
  const asError    = x => isError(x)    ? x : raise('error expected');
  const asIndex    = (i, a) =>
    !Number.isInteger(i)   ? raise(`index ${i} is not valid`) :
    i < 0 || i >= a.length ? raise(`index ${i} is not with array bounds of [0, ${a.length})`) :
    i;
  const asShenBool = x => x ? shenTrue : shenFalse;
  const asJsBool   = x =>
    x === shenTrue  ? true :
    x === shenFalse ? false :
    raise('Shen boolean expected');

  const cons        = (h, t) => new Cons(h, t);
  const toArray     = x => isList(x) ? produce(isCons, c => c.head, c => c.tail, x) : x;
  const toArrayTree = x => isList(x) ? toArray(x).map(toArrayTree) : x;
  const toList      = (x, tail = null) => isArray(x) ? x.reduceRight((t, h) => cons(h, t), tail) : x;
  const toListTree  = x => isArray(x) ? toList(x.map(toListTree)) : x;

  const equateType = (x, y) => x.constructor === y.constructor && equate(Object.keys(x), Object.keys(y));
  const equate     = (x, y) =>
    x === y
    || isCons(x)   && isCons(y)   && equate(x.head, y.head) && equate(x.tail, y.tail)
    || isArray(x)  && isArray(y)  && x.length === y.length  && x.every((v, i) => equate(v, y[i]))
    || isObject(x) && isObject(y) && equateType(x, y)       && Object.keys(x).every(k => equate(x[k], y[k]));

  // Generic (rest/spread) paths, only taken for partial application,
  // over-application, zero-arg re-wrap, or arities above the specialization
  // cutoff. The hot path - calling a wrapper with exactly `arity` arguments -
  // goes through the fixed-parameter wrappers below, which avoid
  // materializing a rest array on every call (a dominant cost on JSC and a
  // measurable one on V8). `args` must be a real array here.
  // settling a sync function's result can still yield a Promise (a sync
  // wrapper may trampoline into an async function), so over-application
  // chains through then() in that case instead of assuming a settled value
  const applyTo = (g, args) =>
    g instanceof Promise
      ? g.then(h => asFunction(h)(...args))
      : asFunction(g)(...args);
  const funSyncGeneric = (f, arity, args) =>
    args.length === arity ? f(...args) :
    args.length > arity ? bounce(() => applyTo(settle(f(...args.slice(0, arity))), args.slice(arity))) :
    args.length === 0 ? funSync(f, arity) :
    Object.assign(funSync((...more) => f(...args, ...more), arity - args.length), { arity: f.arity - args.length });
  const funAsyncGeneric = (f, arity, args) =>
    args.length === arity ? f(...args) :
    args.length > arity ? bounce(async () => asFunction(await settle(f(...args.slice(0, arity))))(...args.slice(arity))) :
    args.length === 0 ? funAsync(f, arity) :
    Object.assign(funAsync((...more) => f(...args, ...more), arity - args.length), { arity: f.arity - args.length });
  // Arity-specialized wrappers: `function` (not arrow) so `arguments` is
  // available to detect exact application without a rest parameter. `this`
  // is unused throughout.
  const slice = args => Array.prototype.slice.call(args);
  const funSyncs = [
    f => function () {
      return arguments.length === 0 ? f() : funSyncGeneric(f, 0, slice(arguments));
    },
    f => function (a) {
      return arguments.length === 1 ? f(a) : funSyncGeneric(f, 1, slice(arguments));
    },
    f => function (a, b) {
      return arguments.length === 2 ? f(a, b) : funSyncGeneric(f, 2, slice(arguments));
    },
    f => function (a, b, c) {
      return arguments.length === 3 ? f(a, b, c) : funSyncGeneric(f, 3, slice(arguments));
    },
    f => function (a, b, c, d) {
      return arguments.length === 4 ? f(a, b, c, d) : funSyncGeneric(f, 4, slice(arguments));
    }
  ];
  // The async wrappers are deliberately PLAIN functions: the wrapped f is
  // itself async, so an async wrapper would allocate a second promise per
  // call that merely resolves to the callee's promise. Returning the
  // callee's promise directly avoids that double layer; callers always go
  // through settle/future/await, which handle promise and non-promise
  // results alike. Since the wrappers are no longer AsyncFunction
  // instances, they carry an own-property `async: true` marker (set in
  // funAsync below) that asyncness checks (fun's dispatch here,
  // js.async? in lib/frontend.js) test alongside instanceof AsyncFunction.
  const funAsyncs = [
    f => function () {
      return arguments.length === 0 ? f() : funAsyncGeneric(f, 0, slice(arguments));
    },
    f => function (a) {
      return arguments.length === 1 ? f(a) : funAsyncGeneric(f, 1, slice(arguments));
    },
    f => function (a, b) {
      return arguments.length === 2 ? f(a, b) : funAsyncGeneric(f, 2, slice(arguments));
    },
    f => function (a, b, c) {
      return arguments.length === 3 ? f(a, b, c) : funAsyncGeneric(f, 3, slice(arguments));
    },
    f => function (a, b, c, d) {
      return arguments.length === 4 ? f(a, b, c, d) : funAsyncGeneric(f, 4, slice(arguments));
    }
  ];
  const funSync = (f, arity) =>
    arity < funSyncs.length ? funSyncs[arity](f) :
    (...args) => funSyncGeneric(f, arity, args);
  const funAsync = (f, arity) =>
    Object.assign(
      arity < funAsyncs.length ? funAsyncs[arity](f) :
      (...args) => funAsyncGeneric(f, arity, args),
      { async: true });
  const isAsync = f => f instanceof AsyncFunction || f.async === true;
  const fun = (f, arity = f.arity || f.length) =>
    Object.assign((isAsync(f) ? funAsync : funSync)(f, arity), { arity });

  const bounce = (f, ...args) => new Trampoline(f, args);
  // only await actual Promises: awaiting an already-settled value still
  // costs a microtask tick, and deep trampoline chains (e.g. the kernel
  // reader's parser combinators) bounce millions of times per file read
  const future = async x => {
    for (;;) {
      if (x instanceof Trampoline) {
        x = x.f(...x.args);
      } else if (x instanceof Promise) {
        x = await x;
      } else {
        return x;
      }
    }
  };
  const settle = x => {
    for (;;) {
      if (x instanceof Trampoline) {
        x = x.f(...x.args);
      } else if (x instanceof Promise) {
        return future(x);
      } else {
        return x;
      }
    }
  };

  const globals = new Map();
  const lookup = name => {
    let cell = globals.get(name);
    if (!cell) {
      cell = new Cell(name);
      globals.set(name, cell);
    }
    return cell;
  };
  const valueOf = x => lookup(x).get();
  const openRead  = options.openRead  || (() => raise('open(in) not supported'));
  const openWrite = options.openWrite || (() => raise('open(out) not supported'));
  const open = (path, mode) =>
    mode === 'in'  ? openRead (asString(valueOf('*home-directory*')) + path) :
    mode === 'out' ? openWrite(asString(valueOf('*home-directory*')) + path) :
    raise(`open only accepts symbols in or out, not ${mode}`);
  const isInStream  = options.isInStream  || (options.InStream  && (x => x instanceof options.InStream))  || (() => false);
  const isOutStream = options.isOutStream || (options.OutStream && (x => x instanceof options.OutStream)) || (() => false);
  const asInStream  = x => isInStream(x)  ? x : raise('input stream expected');
  const asOutStream = x => isOutStream(x) ? x : raise('output stream expected');
  const isStream = x => isInStream(x) || isOutStream(x);
  const asStream = x => isStream(x) ? x : raise('stream expected');
  const clock = options.clock || (() => Date.now() / 1000);
  const startTime = clock();
  const getTime = mode =>
    mode === 'unix' ? clock() :
    mode === 'run'  ? clock() - startTime :
    raise(`get-time only accepts symbols unix or run, not ${mode}`);
  const showCons = x => {
    const { result, state } = produceState(isCons, x => x.head, x => x.tail, x);
    return `[${result.map(show).join(' ')}${state === null ? '' : ` | ${show(state)}`}]`;
  };
  const show = x =>
    x === null    ? '[]' :
    isString(x)   ? `"${x}"` :
    isSymbol(x)   ? nameOf(x) :
    isCons(x)     ? showCons(x) :
    isFunction(x) ? `<Function${x.arity ? ` ${x.arity}` : ''}>` :
    isArray(x)    ? `<Vector ${x.length}>` :
    isError(x)    ? `<Error "${x.toString()}">` :
    isStream(x)   ? `<Stream ${x.name}>` :
    `${x}`;
  const assign = (name, value) => lookup(name).set(value);
  const defun = (name, f) => (lookup(name).f = f.arity ? f : fun(f), symbolOf(name));
  const $ = {
    AsyncFunction,
    cons, toArray, toArrayTree, toList, toListTree,
    asJsBool, asShenBool, isEArray, isNeArray, asNeString, asNzNumber, globals, lookup, assign, defun,
    isStream, isInStream, isOutStream, isNumber, isString, isSymbol, isCons, isList, isArray, isError, isFunction,
    asStream, asInStream, asOutStream, asNumber, asString, asSymbol, asCons, asList, asArray, asError, asFunction,
    symbolOf, nameOf, valueOf, show, equate, raise, fun, bounce, settle,
    b: bounce, d: defun, l: fun, r: toList, s, t: settle, c: lookup
  };
  $.evalJs = _ => raise('eval is not available: no compiler is attached to this runtime');
  $.evalKl = _ => raise('eval is not available: no compiler is attached to this runtime');
  const out = options.stoutput;
  assign('*language*',       'JavaScript');
  assign('*implementation*', options.implementation || 'Unknown');
  assign('*release*',        options.release        || 'Unknown');
  assign('*os*',             options.os             || 'Unknown');
  assign('*port*',           options.port           || 'Unknown');
  assign('*porters*',        options.porters        || 'Unknown');
  assign('*stinput*',        options.stinput        || (() => raise('standard input not supported')));
  assign('*stoutput*',       out                    || (() => raise('standard output not supported')));
  assign('*sterror*',        options.sterror || out || (() => raise('standard output not supported')));
  assign('*home-directory*', options.homeDirectory  || '');
  assign('shen-script.*instream-supported*',  asShenBool(options.isInStream  || options.InStream));
  assign('shen-script.*outstream-supported*', asShenBool(options.isOutStream || options.OutStream));
  // only cons lists are forms: atoms, including absvectors, evaluate to themselves
  defun('eval-kl',           x => isCons(x) ? $.evalKl(x) : x);
  defun('if',        (b, x, y) => asJsBool(b) ? x : y);
  defun('and',          (x, y) => asShenBool(asJsBool(x) && asJsBool(y)));
  defun('or',           (x, y) => asShenBool(asJsBool(x) || asJsBool(y)));
  defun('open',         (p, m) => open(asString(p), nameOf(asSymbol(m))));
  defun('close',             x => (asStream(x).close(), null));
  defun('read-byte',         x => asInStream(x).read());
  defun('write-byte',   (b, x) => (asOutStream(x).write(asNumber(b)), b));
  defun('shen.char-stinput?',     x => asShenBool(isFunction(asInStream(x).readString)));
  defun('shen.char-stoutput?',    x => asShenBool(isFunction(asOutStream(x).writeString)));
  defun('shen.read-unit-string',  x => asInStream(x).readString());
  defun('shen.write-string', (s, x) => (asOutStream(x).writeString(asString(s)), s));
  defun('number?',           x => asShenBool(isNumber(x)));
  defun('string?',           x => asShenBool(isString(x)));
  defun('absvector?',        x => asShenBool(isArray(x)));
  defun('cons?',             x => asShenBool(isCons(x)));
  defun('hd',                c => asCons(c).head);
  defun('tl',                c => asCons(c).tail);
  defun('cons',                   cons);
  defun('tlstr',             x => asNeString(x).substring(1));
  defun('cn',           (x, y) => asString(x) + asString(y));
  defun('string->n',         x => asNeString(x).charCodeAt(0));
  defun('n->string',         n => String.fromCharCode(asNumber(n)));
  defun('pos',          (x, i) => asString(x)[asIndex(i, x)]);
  defun('str',                    show);
  defun('absvector',         n => new Array(asNumber(n)).fill(null));
  defun('<-address',    (a, i) => asArray(a)[asIndex(i, a)]);
  defun('address->', (a, i, x) => (asArray(a)[asIndex(i, a)] = x, a));
  defun('+',            (x, y) => asNumber(x) + asNumber(y));
  defun('-',            (x, y) => asNumber(x) - asNumber(y));
  defun('*',            (x, y) => asNumber(x) * asNumber(y));
  defun('/',            (x, y) => asNumber(x) / asNzNumber(y));
  defun('>',            (x, y) => asShenBool(asNumber(x) >  asNumber(y)));
  defun('<',            (x, y) => asShenBool(asNumber(x) <  asNumber(y)));
  defun('>=',           (x, y) => asShenBool(asNumber(x) >= asNumber(y)));
  defun('<=',           (x, y) => asShenBool(asNumber(x) <= asNumber(y)));
  defun('=',            (x, y) => asShenBool(equate(x, y)));
  defun('intern',            x => symbolOf(asString(x)));
  defun('get-time',          x => getTime(nameOf(asSymbol(x))));
  defun('simple-error',      x => raise(asString(x)));
  defun('error-to-string',   x => asError(x).message);
  defun('set',          (x, y) => lookup(nameOf(asSymbol(x))).set(y));
  defun('value',             x => valueOf(nameOf(asSymbol(x))));
  defun('type',         (x, _) => x);
  return $;
};

const overrides = $ => {
  const {
    asArray, asCons, asNumber, asOutStream, asShenBool, asString, cons, defun, equate,
    isArray, isCons, isSymbol, lookup, nameOf, raise, s, settle, toArray, toList, valueOf
  } = $;
  const asMap = x => x instanceof Map ? x : raise('dict expected');
  const isUpper = x => x >= 65 && x <= 90;
  const pvar = s`shen.pvar`;
  const tuple = s`shen.tuple`;
  const t$ = s`true`;
  const f$ = s`false`;
  defun('@p', (x, y) => [tuple, x, y]);
  defun('shen.pvar?', x => asShenBool(isArray(x) && x.length > 0 && x[0] === pvar));
  defun('shen.byte->digit', x => x - 48);
  defun('integer?', x => asShenBool(Number.isInteger(x)));
  defun('symbol?', x => asShenBool(isSymbol(x) && x !== t$ && x !== f$));
  defun('variable?', x => asShenBool(isSymbol(x) && isUpper(nameOf(x).charCodeAt(0))));
  defun('shen.fillvector', (xs, i, max, x) => asArray(xs).fill(x, asNumber(i), asNumber(max) + 1));
  defun('put', (x, p, y, d) => {
    const current = asMap(d).has(x) ? d.get(x) : null;
    const array = toArray(current);
    for (const element of array) {
      if (equate(p, asCons(element).head)) {
        element.tail = y;
        d.set(x, toList(array));
        return y;
      }
    }
    array.push(cons(p, y));
    d.set(x, toList(array));
    return y;
  });
  defun('shen.dict', _ => new Map());
  defun('shen.dict?', x => asShenBool(x instanceof Map));
  defun('shen.dict-count', d => asMap(d).size);
  defun('shen.dict->', (d, k, v) => (asMap(d).set(k, v), v));
  defun('shen.<-dict', (d, k) => asMap(d).has(k) ? d.get(k) : raise(`value ${$.show(k)} not found in dict\n`));
  defun('shen.dict-rm', (d, k) => (asMap(d).delete(k), k));
  defun('shen.dict-fold', async (f, d, acc) => {
    for (const [k, v] of asMap(d)) {
      acc = await settle(f(k, v, acc));
    }
    return acc;
  });
  defun('shen.dict-keys', d => toList([...asMap(d).keys()]));
  defun('shen.dict-values', d => toList([...asMap(d).values()]));
  // native macroexpand: macro fns may return equal-but-freshly-built nodes on a
  // miss, so equality is checked locally at each macro-return site and original
  // references are kept whenever there is no semantic change. that preserves
  // identity all the way up the tree and makes the per-pass fixpoint check pure
  // reference equality instead of a full-tree deep compare.
  const applyMacro = async (f, x) => {
    const w = await settle(f(x));
    return w === x || equate(w, x) ? x : w;
  };
  const macroWalk = async (f, x) => {
    if (isCons(x)) {
      let changed = false;
      const items = [];
      for (let c = x; isCons(c); c = c.tail) {
        const w = await macroWalk(f, c.head);
        changed = changed || w !== c.head;
        items.push(w);
      }
      const rebuilt = changed ? toList(items) : x;
      return await applyMacro(f, rebuilt);
    }
    return await applyMacro(f, x);
  };
  defun('macroexpand', async x => {
    const fns = toArray(valueOf('*macros*')).map(p => asCons(p).tail);
    let v = x;
    for (let i = 0; i < fns.length;) {
      const w = await macroWalk(fns[i], v);
      if (w === v) {
        i++;
      } else {
        v = w;
        i = 0;
      }
    }
    return v;
  });
  // The kernel's KL pr is gated on *hush*, which silences EVERY pr - even
  // writes to file sinks, so `shen eval -q ...` would emit empty output
  // files. shen-cl overrides pr natively with an unconditional write (its -q
  // does not silence pr at all); match the reference host. Char-capable
  // streams take the whole string, byte streams get it byte-by-byte exactly
  // as the kernel's shen.write-chars would.
  defun('pr', (str, stm) => {
    const out = asOutStream(stm);
    asString(str);
    if (typeof out.writeString === 'function') {
      out.writeString(str);
    } else {
      for (let i = 0; i < str.length; i++) {
        out.write(str.charCodeAt(i));
      }
    }
    return str;
  });
  const oldShow = $.show;
  $.show = x => x instanceof Map ? `<Dict ${x.size}>` : oldShow(x);
  const credits = lookup('shen.credits').f;
  const pr = lookup('pr').f;
  const stoutput = lookup('*stoutput*');
  defun('shen.credits', async () => {
    await settle(credits());
    return await settle(pr('exit REPL with (node.exit)', stoutput.get()));
  });
  return $;
};

const run = async $ => {
  let w$;
  const false$s = ($.s)`false`;
  const absvector$c = $.c("absvector");
  const address$2d$3e$c = $.c("address->");
  const shen$2efillvector$c = $.c("shen.fillvector");
  const fail$c = $.c("fail");
  const $3c$2daddress$c = $.c("<-address");
  const boolean$3f$c = $.c("boolean?");
  const empty$3f$c = $.c("empty?");
  const vector$3f$c = $.c("vector?");
  const element$3f$c = $.c("element?");
  const $7b$s = ($.s)`{`;
  const $7d$s = ($.s)`}`;
  const true$s = ($.s)`true`;
  const shen$2eanalyse$2dsymbol$3f$c = $.c("shen.analyse-symbol?");
  const shen$2e$2bstring$3f$c = $.c("shen.+string?");
  const shen$2ealpha$3f$c = $.c("shen.alpha?");
  const hdstr$c = $.c("hdstr");
  const shen$2ealphanums$3f$c = $.c("shen.alphanums?");
  const shen$2edigit$3f$c = $.c("shen.digit?");
  const concat$c = $.c("concat");
  const shen$2e$2agensym$2a$c = $.c("shen.*gensym*");
  const append$c = $.c("append");
  const assoc$c = $.c("assoc");
  const shen$2eassoc$2dset$c = $.c("shen.assoc-set");
  const shen$2ef$2derror$c = $.c("shen.f-error");
  const shen$2eassoc$2dset$s = ($.s)`shen.assoc-set`;
  const shen$2e$3c$2ddict$c = $.c("shen.<-dict");
  const shen$2edict$2d$3e$c = $.c("shen.dict->");
  const shen$2eapp$c = $.c("shen.app");
  const shen$2es$s = ($.s)`shen.s`;
  const shen$2ea$s = ($.s)`shen.a`;
  const shen$2emod$c = $.c("shen.mod");
  const shen$2ehashkey$c = $.c("shen.hashkey");
  const map$c = $.c("map");
  const explode$c = $.c("explode");
  const shen$2eprodbutzero$c = $.c("shen.prodbutzero");
  const shen$2eprodbutzero$s = ($.s)`shen.prodbutzero`;
  const shen$2emodh$c = $.c("shen.modh");
  const shen$2emultiples$c = $.c("shen.multiples");
  const pos$c = $.c("pos");
  const shen$2ereverse$2dhelp$c = $.c("shen.reverse-help");
  const shen$2eexplode$2dh$c = $.c("shen.explode-h");
  const shen$2emap$2dh$c = $.c("shen.map-h");
  const reverse$c = $.c("reverse");
  const shen$2emap$2dh$s = ($.s)`shen.map-h`;
  const shen$2elength$2dh$c = $.c("shen.length-h");
  const shen$2eabs$c = $.c("shen.abs");
  const shen$2einteger$2dtest$3f$c = $.c("shen.integer-test?");
  const shen$2emagless$c = $.c("shen.magless");
  const integer$3f$c = $.c("integer?");
  const symbol$3f$c = $.c("symbol?");
  const shen$2ethis$2dsymbol$2dis$2dunbound$s = ($.s)`shen.this-symbol-is-unbound`;
  const shen$2efail$21$s = ($.s)`shen.fail!`;
  const shen$2edictionary$s = ($.s)`shen.dictionary`;
  const length$c = $.c("length");
  const shen$2edict$2dcount$2d$3e$c = $.c("shen.dict-count->");
  const shen$2edict$2dcount$c = $.c("shen.dict-count");
  const hash$c = $.c("hash");
  const shen$2edict$2dcapacity$c = $.c("shen.dict-capacity");
  const shen$2e$3c$2ddict$2dbucket$c = $.c("shen.<-dict-bucket");
  const shen$2edict$2dbucket$2d$3e$c = $.c("shen.dict-bucket->");
  const shen$2edict$2dupdate$2dcount$c = $.c("shen.dict-update-count");
  const shen$2eassoc$2d$3e$c = $.c("shen.assoc->");
  const shen$2elowercase$3f$c = $.c("shen.lowercase?");
  const shen$2euppercase$3f$c = $.c("shen.uppercase?");
  const shen$2emisc$3f$c = $.c("shen.misc?");
  const arity$c = $.c("arity");
  const get$c = $.c("get");
  const shen$2elambda$2dform$s = ($.s)`shen.lambda-form`;
  const $2aproperty$2dvector$2a$c = $.c("*property-vector*");
  const shen$2enot$2dpvar$s = ($.s)`shen.not-pvar`;
  const shen$2epvar$s = ($.s)`shen.pvar`;
  const shen$2epvar$3f$c = $.c("shen.pvar?");
  const shen$2e$2dnull$2d$s = ($.s)`shen.-null-`;
  const shen$2elazyderef$c = $.c("shen.lazyderef");
  const shen$2ederef$c = $.c("shen.deref");
  const shen$2ebindv$c = $.c("shen.bindv");
  const thaw$c = $.c("thaw");
  const shen$2eunwind$c = $.c("shen.unwind");
  const shen$2eticket$2dnumber$c = $.c("shen.ticket-number");
  const shen$2edecrement$2dticket$c = $.c("shen.decrement-ticket");
  const shen$2emake$2dprolog$2dvariable$c = $.c("shen.make-prolog-variable");
  const shen$2enextticket$c = $.c("shen.nextticket");
  const shen$2eoccurs$2dcheck$3f$c = $.c("shen.occurs-check?");
  const shen$2ebind$21$c = $.c("shen.bind!");
  const shen$2elzy$3d$21$c = $.c("shen.lzy=!");
  const shen$2earg$2d$3estr$c = $.c("shen.arg->str");
  const shen$2elist$3f$c = $.c("shen.list?");
  const shen$2elist$2d$3estr$c = $.c("shen.list->str");
  const shen$2estr$2d$3estr$c = $.c("shen.str->str");
  const shen$2evector$2d$3estr$c = $.c("shen.vector->str");
  const shen$2eatom$2d$3estr$c = $.c("shen.atom->str");
  const shen$2er$s = ($.s)`shen.r`;
  const $40s$c = $.c("@s");
  const shen$2eiter$2dlist$c = $.c("shen.iter-list");
  const shen$2emaxseq$c = $.c("shen.maxseq");
  const $2amaximum$2dprint$2dsequence$2dsize$2a$c = $.c("*maximum-print-sequence-size*");
  const shen$2eprint$2dvector$3f$c = $.c("shen.print-vector?");
  const fn$c = $.c("fn");
  const shen$2eiter$2dvector$c = $.c("shen.iter-vector");
  const shen$2e$2aempty$2dabsvector$2a$c = $.c("shen.*empty-absvector*");
  const shen$2eempty$2dabsvector$3f$c = $.c("shen.empty-absvector?");
  const shen$2etuple$s = ($.s)`shen.tuple`;
  const shen$2efbound$3f$c = $.c("shen.fbound?");
  const shen$2eout$2dof$2dbounds$s = ($.s)`shen.out-of-bounds`;
  const shen$2efunexstring$c = $.c("shen.funexstring");
  const gensym$c = $.c("gensym");
  const shen$2e$2aprolog$2dmemory$2a$c = $.c("shen.*prolog-memory*");
  const arity$s = ($.s)`arity`;
  const put$c = $.c("put");
  const shen$2einitialise$2darity$2dtable$c = $.c("shen.initialise-arity-table");
  const shen$2eset$2dlambda$2dform$2dentry$s = ($.s)`shen.set-lambda-form-entry`;
  const shen$2e$2ahistory$2a$c = $.c("shen.*history*");
  const shen$2e$2atc$2a$c = $.c("shen.*tc*");
  const shen$2edict$c = $.c("shen.dict");
  const $2amacros$2a$c = $.c("*macros*");
  const shen$2e$2atracking$2a$c = $.c("shen.*tracking*");
  const shen$2e$2aprofiled$2a$c = $.c("shen.*profiled*");
  const shen$2e$2aspecial$2a$c = $.c("shen.*special*");
  const $40p$s = ($.s)`@p`;
  const $40s$s = ($.s)`@s`;
  const $40v$s = ($.s)`@v`;
  const cons$s = ($.s)`cons`;
  const lambda$s = ($.s)`lambda`;
  const let$s = ($.s)`let`;
  const where$s = ($.s)`where`;
  const set$s = ($.s)`set`;
  const open$s = ($.s)`open`;
  const input$2b$s = ($.s)`input+`;
  const type$s = ($.s)`type`;
  const shen$2e$2aextraspecial$2a$c = $.c("shen.*extraspecial*");
  const shen$2e$2aspy$2a$c = $.c("shen.*spy*");
  const shen$2e$2adatatypes$2a$c = $.c("shen.*datatypes*");
  const shen$2e$2aalldatatypes$2a$c = $.c("shen.*alldatatypes*");
  const shen$2e$2ashen$2dtype$2dtheory$2denabled$3f$2a$c = $.c("shen.*shen-type-theory-enabled?*");
  const shen$2e$2apackage$2a$c = $.c("shen.*package*");
  const null$s = ($.s)`null`;
  const shen$2e$2asynonyms$2a$c = $.c("shen.*synonyms*");
  const shen$2e$2asystem$2a$c = $.c("shen.*system*");
  const shen$2e$2aoccurs$2a$c = $.c("shen.*occurs*");
  const shen$2e$2afactorise$3f$2a$c = $.c("shen.*factorise?*");
  const shen$2e$2amaxinferences$2a$c = $.c("shen.*maxinferences*");
  const shen$2e$2acall$2a$c = $.c("shen.*call*");
  const shen$2e$2ainfs$2a$c = $.c("shen.*infs*");
  const $2ahush$2a$c = $.c("*hush*");
  const shen$2e$2aoptimise$2a$c = $.c("shen.*optimise*");
  const $2aversion$2a$c = $.c("*version*");
  const shen$2e$2anames$2a$c = $.c("shen.*names*");
  const shen$2e$2astep$2a$c = $.c("shen.*step*");
  const shen$2e$2ait$2a$c = $.c("shen.*it*");
  const shen$2e$2aresidue$2a$c = $.c("shen.*residue*");
  const $2aabsolute$2a$c = $.c("*absolute*");
  const shen$2e$2aloading$3f$2a$c = $.c("shen.*loading?*");
  const shen$2e$2auserdefs$2a$c = $.c("shen.*userdefs*");
  const shen$2e$2ademodulation$2dfunction$2a$c = $.c("shen.*demodulation-function*");
  const shen$2e$2acustom$2dpattern$2dcompiler$2a$c = $.c("shen.*custom-pattern-compiler*");
  const shen$2e$2acustom$2dpattern$2dreducer$2a$c = $.c("shen.*custom-pattern-reducer*");
  const bound$3f$c = $.c("bound?");
  const $2ahome$2ddirectory$2a$s = ($.s)`*home-directory*`;
  const $2ahome$2ddirectory$2a$c = $.c("*home-directory*");
  const shen$2eskip$s = ($.s)`shen.skip`;
  const $2asterror$2a$s = ($.s)`*sterror*`;
  const $2asterror$2a$c = $.c("*sterror*");
  const $2astoutput$2a$c = $.c("*stoutput*");
  const prolog$2dmemory$c = $.c("prolog-memory");
  const absvector$3f$s = ($.s)`absvector?`;
  const absvector$s = ($.s)`absvector`;
  const address$2d$3e$s = ($.s)`address->`;
  const and$s = ($.s)`and`;
  const append$s = ($.s)`append`;
  const assoc$s = ($.s)`assoc`;
  const boolean$3f$s = ($.s)`boolean?`;
  const bound$3f$s = ($.s)`bound?`;
  const concat$s = ($.s)`concat`;
  const cons$3f$s = ($.s)`cons?`;
  const cn$s = ($.s)`cn`;
  const close$s = ($.s)`close`;
  const do$s = ($.s)`do`;
  const element$3f$s = ($.s)`element?`;
  const empty$3f$s = ($.s)`empty?`;
  const error$2dto$2dstring$s = ($.s)`error-to-string`;
  const explode$s = ($.s)`explode`;
  const fail$s = ($.s)`fail`;
  const freeze$s = ($.s)`freeze`;
  const fn$s = ($.s)`fn`;
  const gensym$s = ($.s)`gensym`;
  const get$s = ($.s)`get`;
  const get$2dtime$s = ($.s)`get-time`;
  const $3c$2daddress$s = ($.s)`<-address`;
  const $3e$s = ($.s)`>`;
  const $3e$3d$s = ($.s)`>=`;
  const $3d$s = ($.s)`=`;
  const hash$s = ($.s)`hash`;
  const hd$s = ($.s)`hd`;
  const hdstr$s = ($.s)`hdstr`;
  const if$s = ($.s)`if`;
  const integer$3f$s = ($.s)`integer?`;
  const intern$s = ($.s)`intern`;
  const is$21$s = ($.s)`is!`;
  const length$s = ($.s)`length`;
  const $3c$s = ($.s)`<`;
  const $3c$3d$s = ($.s)`<=`;
  const vector$s = ($.s)`vector`;
  const map$s = ($.s)`map`;
  const not$s = ($.s)`not`;
  const n$2d$3estring$s = ($.s)`n->string`;
  const number$3f$s = ($.s)`number?`;
  const or$s = ($.s)`or`;
  const pos$s = ($.s)`pos`;
  const prolog$2dmemory$s = ($.s)`prolog-memory`;
  const put$s = ($.s)`put`;
  const read$2dbyte$s = ($.s)`read-byte`;
  const shen$2eread$2dunit$2dstring$s = ($.s)`shen.read-unit-string`;
  const reverse$s = ($.s)`reverse`;
  const simple$2derror$s = ($.s)`simple-error`;
  const str$s = ($.s)`str`;
  const string$2d$3en$s = ($.s)`string->n`;
  const string$3f$s = ($.s)`string?`;
  const symbol$3f$s = ($.s)`symbol?`;
  const tl$s = ($.s)`tl`;
  const thaw$s = ($.s)`thaw`;
  const tlstr$s = ($.s)`tlstr`;
  const trap$2derror$s = ($.s)`trap-error`;
  const vector$3f$s = ($.s)`vector?`;
  const value$s = ($.s)`value`;
  const write$2dbyte$s = ($.s)`write-byte`;
  const $2b$s = ($.s)`+`;
  const $2a$s = ($.s)`*`;
  const $2f$s = ($.s)`/`;
  const $2d$s = ($.s)`-`;
  const shen$s = ($.s)`shen`;
  const shen$2eexternal$2dsymbols$s = ($.s)`shen.external-symbols`;
  const $2astinput$2a$s = ($.s)`*stinput*`;
  const $2astoutput$2a$s = ($.s)`*stoutput*`;
  const defun$s = ($.s)`defun`;
  const cond$s = ($.s)`cond`;
  const shen$2e$2asigf$2a$c = $.c("shen.*sigf*");
  const abort$s = ($.s)`abort`;
  const shen$2enewpv$c = $.c("shen.newpv");
  const shen$2egc$c = $.c("shen.gc");
  const is$21$c = $.c("is!");
  const $2d$2d$3e$s = ($.s)`-->`;
  const absolute$s = ($.s)`absolute`;
  const string$s = ($.s)`string`;
  const list$s = ($.s)`list`;
  const boolean$s = ($.s)`boolean`;
  const adjoin$s = ($.s)`adjoin`;
  const shen$2eapp$s = ($.s)`shen.app`;
  const symbol$s = ($.s)`symbol`;
  const number$s = ($.s)`number`;
  const atom$3f$s = ($.s)`atom?`;
  const bootstrap$s = ($.s)`bootstrap`;
  const shen$2eccons$3f$s = ($.s)`shen.ccons?`;
  const cd$s = ($.s)`cd`;
  const stream$s = ($.s)`stream`;
  const compile$s = ($.s)`compile`;
  const datatypes$s = ($.s)`datatypes`;
  const destroy$s = ($.s)`destroy`;
  const difference$s = ($.s)`difference`;
  const $3ce$3e$s = ($.s)`<e>`;
  const $3c$21$3e$s = ($.s)`<!>`;
  const $3cend$3e$s = ($.s)`<end>`;
  const shen$2eparse$2dfailure$3f$s = ($.s)`shen.parse-failure?`;
  const shen$2eparse$2dfailure$s = ($.s)`shen.parse-failure`;
  const shen$2e$3c$2dout$s = ($.s)`shen.<-out`;
  const shen$2ein$2d$3e$s = ($.s)`shen.in->`;
  const shen$2ecomb$s = ($.s)`shen.comb`;
  const enable$2dtype$2dtheory$s = ($.s)`enable-type-theory`;
  const external$s = ($.s)`external`;
  const exception$s = ($.s)`exception`;
  const factorise$s = ($.s)`factorise`;
  const factorise$3f$s = ($.s)`factorise?`;
  const fix$s = ($.s)`fix`;
  const lazy$s = ($.s)`lazy`;
  const fst$s = ($.s)`fst`;
  const shen$2ehds$3d$3f$s = ($.s)`shen.hds=?`;
  const hush$s = ($.s)`hush`;
  const hush$3f$s = ($.s)`hush?`;
  const $3c$2dvector$s = ($.s)`<-vector`;
  const vector$2d$3e$s = ($.s)`vector->`;
  const head$s = ($.s)`head`;
  const hdv$s = ($.s)`hdv`;
  const in$2dpackage$s = ($.s)`in-package`;
  const it$s = ($.s)`it`;
  const implementation$s = ($.s)`implementation`;
  const include$s = ($.s)`include`;
  const include$2dall$2dbut$s = ($.s)`include-all-but`;
  const included$s = ($.s)`included`;
  const inferences$s = ($.s)`inferences`;
  const shen$2einsert$s = ($.s)`shen.insert`;
  const internal$s = ($.s)`internal`;
  const intersection$s = ($.s)`intersection`;
  const language$s = ($.s)`language`;
  const limit$s = ($.s)`limit`;
  const lineread$s = ($.s)`lineread`;
  const in$s = ($.s)`in`;
  const unit$s = ($.s)`unit`;
  const load$s = ($.s)`load`;
  const mapcan$s = ($.s)`mapcan`;
  const maxinferences$s = ($.s)`maxinferences`;
  const nl$s = ($.s)`nl`;
  const nth$s = ($.s)`nth`;
  const occurrences$s = ($.s)`occurrences`;
  const occurs$2dcheck$s = ($.s)`occurs-check`;
  const occurs$3f$s = ($.s)`occurs?`;
  const optimise$s = ($.s)`optimise`;
  const optimise$3f$s = ($.s)`optimise?`;
  const os$s = ($.s)`os`;
  const package$3f$s = ($.s)`package?`;
  const port$s = ($.s)`port`;
  const porters$s = ($.s)`porters`;
  const pr$s = ($.s)`pr`;
  const out$s = ($.s)`out`;
  const print$s = ($.s)`print`;
  const profile$s = ($.s)`profile`;
  const preclude$s = ($.s)`preclude`;
  const shen$2eproc$2dnl$s = ($.s)`shen.proc-nl`;
  const profile$2dresults$s = ($.s)`profile-results`;
  const protect$s = ($.s)`protect`;
  const preclude$2dall$2dbut$s = ($.s)`preclude-all-but`;
  const shen$2eprhush$s = ($.s)`shen.prhush`;
  const ps$s = ($.s)`ps`;
  const read$s = ($.s)`read`;
  const read$2dfile$2das$2dbytelist$s = ($.s)`read-file-as-bytelist`;
  const read$2dfile$2das$2dstring$s = ($.s)`read-file-as-string`;
  const read$2dfile$s = ($.s)`read-file`;
  const read$2dfrom$2dstring$s = ($.s)`read-from-string`;
  const read$2dfrom$2dstring$2dunprocessed$s = ($.s)`read-from-string-unprocessed`;
  const release$s = ($.s)`release`;
  const remove$s = ($.s)`remove`;
  const snd$s = ($.s)`snd`;
  const specialise$s = ($.s)`specialise`;
  const spy$s = ($.s)`spy`;
  const shen$2espy$3f$s = ($.s)`shen.spy?`;
  const step$s = ($.s)`step`;
  const shen$2estep$3f$s = ($.s)`shen.step?`;
  const stinput$s = ($.s)`stinput`;
  const sterror$s = ($.s)`sterror`;
  const stoutput$s = ($.s)`stoutput`;
  const string$2d$3esymbol$s = ($.s)`string->symbol`;
  const sum$s = ($.s)`sum`;
  const systemf$s = ($.s)`systemf`;
  const system$2dS$3f$s = ($.s)`system-S?`;
  const tail$s = ($.s)`tail`;
  const tlv$s = ($.s)`tlv`;
  const tc$s = ($.s)`tc`;
  const tc$3f$s = ($.s)`tc?`;
  const track$s = ($.s)`track`;
  const tracked$s = ($.s)`tracked`;
  const tuple$3f$s = ($.s)`tuple?`;
  const unabsolute$s = ($.s)`unabsolute`;
  const undefmacro$s = ($.s)`undefmacro`;
  const union$s = ($.s)`union`;
  const unprofile$s = ($.s)`unprofile`;
  const untrack$s = ($.s)`untrack`;
  const userdefs$s = ($.s)`userdefs`;
  const variable$3f$s = ($.s)`variable?`;
  const version$s = ($.s)`version`;
  const write$2dto$2dfile$s = ($.s)`write-to-file`;
  const y$2dor$2dn$3f$s = ($.s)`y-or-n?`;
  const $3d$3d$s = ($.s)`==`;
  const shen$2eset$2dlambda$2dform$2dentry$c = $.c("shen.set-lambda-form-entry");
  const shen$2etuple$c = $.c("shen.tuple");
  const shen$2epvar$c = $.c("shen.pvar");
  const shen$2edictionary$c = $.c("shen.dictionary");
  const vector$c = $.c("vector");
  const shen$2einitialise$2denvironment$c = $.c("shen.initialise-environment");
  const shen$2einitialise$2dlambda$2dforms$c = $.c("shen.initialise-lambda-forms");
  const shen$2einitialise$2dsignedfuncs$c = $.c("shen.initialise-signedfuncs");
  const shen$2einitialise$c = $.c("shen.initialise");
  const string$2dlength$c = $.c("string-length");
  const find$2dval$c = $.c("find-val");
  const s$s = ($.s)`s`;
  const obj$s = ($.s)`obj`;
  const check$2dstring$c = $.c("check-string");
  const validate$2dmessage$c = $.c("validate-message");
  $.d("shen.+string?", $.l(V859 => "" === V859 ? false$s : $.asShenBool($.isString(V859))));
  $.d("thaw", $.l(V3767 => $.b(V3767)));
  $.d("@s", $.l((V3775, V3776) => $.asString(V3775) + $.asString(V3776)));
  $.d("vector", $.l(async V3779 => {
    let w$, W3780$t0, W3781$t1, W3782$t2;
    return (W3780$t0 = absvector$c.f($.asNumber(V3779) + 1), (W3781$t1 = address$2d$3e$c.f(W3780$t0, 0, V3779), (W3782$t2 = V3779 === 0 ? W3781$t1 : (w$ = $.t(shen$2efillvector$c.f(W3781$t1, 1, V3779, (w$ = $.t(fail$c.f())) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, W3782$t2)));
  }));
  $.d("shen.fillvector", $.l((V3784, V3785, V3786, V3787) => $.equate(V3785, V3786) ? address$2d$3e$c.f(V3784, V3786, V3787) : $.b(shen$2efillvector$c.f, address$2d$3e$c.f(V3784, V3785, V3787), 1 + $.asNumber(V3785), V3786, V3787)));
  $.d("vector?", $.l(async V3788 => {
    let W3789$t0;
    return $.asShenBool($.isArray(V3788) && $.asJsBool((W3789$t0 = await (async () => {
      let w$;
      try {
        return (w$ = $.t($3c$2daddress$c.f(V3788, 0))) instanceof Promise ? await w$ : w$;
      } catch (Z3790) {
        return -1;
      }
    })(), $.asShenBool($.isNumber(W3789$t0) && W3789$t0 >= 0))));
  }));
  $.d("symbol?", $.l(async V3799 => {
    let w$, W3800$t0;
    return $.asJsBool((w$ = $.t(boolean$3f$c.f(V3799))) instanceof Promise ? await w$ : w$) || ($.isNumber(V3799) || ($.isString(V3799) || ($.isCons(V3799) || ($.asJsBool((w$ = $.t(empty$3f$c.f(V3799))) instanceof Promise ? await w$ : w$) || $.asJsBool((w$ = $.t(vector$3f$c.f(V3799))) instanceof Promise ? await w$ : w$))))) ? false$s : $.asJsBool((w$ = $.t(element$3f$c.f(V3799, $.r([$7b$s, $7d$s, $.symbolOf(":"), $.symbolOf(";"), $.symbolOf(",")])))) instanceof Promise ? await w$ : w$) ? true$s : await (async () => {
      let w$;
      try {
        return (W3800$t0 = $.show(V3799), (w$ = $.t(shen$2eanalyse$2dsymbol$3f$c.f(W3800$t0))) instanceof Promise ? await w$ : w$);
      } catch (Z3801) {
        return false$s;
      }
    })();
  }));
  $.d("shen.analyse-symbol?", $.l(async V3804 => {
    let w$;
    return $.asJsBool((w$ = $.t(shen$2e$2bstring$3f$c.f(V3804))) instanceof Promise ? await w$ : w$) ? $.asShenBool($.asJsBool((w$ = $.t(shen$2ealpha$3f$c.f($.asNeString((w$ = $.t(hdstr$c.f(V3804))) instanceof Promise ? await w$ : w$).charCodeAt(0)))) instanceof Promise ? await w$ : w$) && $.asJsBool((w$ = $.t(shen$2ealphanums$3f$c.f($.asNeString(V3804).substring(1)))) instanceof Promise ? await w$ : w$)) : $.raise("implementation error in shen.analyse-symbol?");
  }));
  $.d("shen.alphanums?", $.l(async V3807 => {
    let w$, W3808$t0;
    return "" === V3807 ? true$s : $.asJsBool((w$ = $.t(shen$2e$2bstring$3f$c.f(V3807))) instanceof Promise ? await w$ : w$) ? (W3808$t0 = $.asNeString((w$ = $.t(hdstr$c.f(V3807))) instanceof Promise ? await w$ : w$).charCodeAt(0), $.asShenBool(($.asJsBool((w$ = $.t(shen$2ealpha$3f$c.f(W3808$t0))) instanceof Promise ? await w$ : w$) || $.asJsBool((w$ = $.t(shen$2edigit$3f$c.f(W3808$t0))) instanceof Promise ? await w$ : w$)) && $.asJsBool((w$ = $.t(shen$2ealphanums$3f$c.f($.asNeString(V3807).substring(1)))) instanceof Promise ? await w$ : w$))) : $.raise("implementation error in shen.alphanums?");
  }));
  $.d("gensym", $.l(V3815 => $.b(concat$c.f, V3815, shen$2e$2agensym$2a$c.set(1 + $.asNumber(shen$2e$2agensym$2a$c.get())))));
  $.d("concat", $.l((V3816, V3817) => $.symbolOf($.show(V3816) + $.show(V3817))));
  $.d("append", $.l((V3832, V3833) => null === V3832 ? V3833 : $.isCons(V3832) ? $.r([V3832.head], $.t(append$c.f(V3832.tail, V3833))) : $.raise("attempt to append a non-list")));
  $.d("assoc", $.l((V3870, V3871) => null === V3871 ? null : $.isCons(V3871) && ($.isCons(V3871.head) && $.equate(V3870, $.asCons(V3871.head).head)) ? $.asCons(V3871).head : $.isCons(V3871) ? $.b(assoc$c.f, V3870, V3871.tail) : $.raise("attempt to search a non-list with assoc\n")));
  $.d("shen.assoc-set", $.l(async (V3875, V3876, V3877) => {
    let w$;
    return null === V3877 ? $.r([$.r([V3875], V3876)]) : $.isCons(V3877) && ($.isCons(V3877.head) && $.equate(V3875, $.asCons(V3877.head).head)) ? $.r([$.r([$.asCons($.asCons(V3877).head).head], V3876)], $.asCons(V3877).tail) : $.isCons(V3877) ? $.r([V3877.head], (w$ = $.t(shen$2eassoc$2dset$c.f(V3875, V3876, V3877.tail))) instanceof Promise ? await w$ : w$) : $.b(shen$2ef$2derror$c.f, shen$2eassoc$2dset$s);
  }));
  $.d("boolean?", $.l(V3885 => true$s === V3885 ? true$s : false$s === V3885 ? true$s : false$s));
  $.d("do", $.l((V3895, V3896) => V3896));
  $.d("element?", $.l((V3908, V3909) => null === V3909 ? false$s : $.isCons(V3909) && $.equate(V3908, V3909.head) ? true$s : $.isCons(V3909) ? $.b(element$3f$c.f, V3908, V3909.tail) : $.raise("attempt to find an element in a non-list\n")));
  $.d("empty?", $.l(V3912 => null === V3912 ? true$s : false$s));
  $.d("put", $.l(async (V3923, V3924, V3925, V3926) => {
    let w$, W3927$t0, W3929$t1, W3930$t2;
    return (W3927$t0 = await (async () => {
      let w$;
      try {
        return (w$ = $.t(shen$2e$3c$2ddict$c.f(V3926, V3923))) instanceof Promise ? await w$ : w$;
      } catch (Z3928) {
        return null;
      }
    })(), (W3929$t1 = (w$ = $.t(shen$2eassoc$2dset$c.f(V3924, V3925, W3927$t0))) instanceof Promise ? await w$ : w$, (W3930$t2 = (w$ = $.t(shen$2edict$2d$3e$c.f(V3926, V3923, W3929$t1))) instanceof Promise ? await w$ : w$, V3925)));
  }));
  $.d("get", $.l(async (V3938, V3939, V3940) => {
    let w$, W3941$t0, W3943$t1;
    return (W3941$t0 = await (async () => {
      let w$;
      try {
        return (w$ = $.t(shen$2e$3c$2ddict$c.f(V3940, V3938))) instanceof Promise ? await w$ : w$;
      } catch (Z3942) {
        return $.raise($.asString((w$ = $.t(shen$2eapp$c.f(V3938, " has no attributes: " + $.asString((w$ = $.t(shen$2eapp$c.f(V3939, "\n", shen$2es$s))) instanceof Promise ? await w$ : w$), shen$2ea$s))) instanceof Promise ? await w$ : w$));
      }
    })(), (W3943$t1 = (w$ = $.t(assoc$c.f(V3939, W3941$t0))) instanceof Promise ? await w$ : w$, $.asJsBool((w$ = $.t(empty$3f$c.f(W3943$t1))) instanceof Promise ? await w$ : w$) ? $.raise("attribute " + $.asString((w$ = $.t(shen$2eapp$c.f(V3939, " not found for " + $.asString((w$ = $.t(shen$2eapp$c.f(V3938, "\n", shen$2es$s))) instanceof Promise ? await w$ : w$), shen$2es$s))) instanceof Promise ? await w$ : w$)) : $.asCons(W3943$t1).tail));
  }));
  $.d("hash", $.l(async (V3944, V3945) => {
    let w$, W3946$t0;
    return (W3946$t0 = (w$ = $.t(shen$2emod$c.f((w$ = $.t(shen$2ehashkey$c.f(V3944))) instanceof Promise ? await w$ : w$, V3945))) instanceof Promise ? await w$ : w$, W3946$t0 === 0 ? 1 : W3946$t0);
  }));
  $.d("shen.hashkey", $.l(async V3947 => {
    let w$, W3948$t0;
    return (W3948$t0 = (w$ = $.t(map$c.f($.l(Z3949 => $.asNeString(Z3949).charCodeAt(0)), (w$ = $.t(explode$c.f(V3947))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, $.b(shen$2eprodbutzero$c.f, W3948$t0, 1));
  }));
  $.d("shen.prodbutzero", $.l((V3950, V3951) => null === V3950 ? V3951 : $.isCons(V3950) && 0 === V3950.head ? $.b(shen$2eprodbutzero$c.f, $.asCons(V3950).tail, V3951) : $.isCons(V3950) ? $.asNumber(V3951) > 10000000000 ? $.b(shen$2eprodbutzero$c.f, V3950.tail, $.asNumber(V3951) + $.asNumber(V3950.head)) : $.b(shen$2eprodbutzero$c.f, V3950.tail, $.asNumber(V3951) * $.asNumber(V3950.head)) : $.b(shen$2ef$2derror$c.f, shen$2eprodbutzero$s)));
  $.d("shen.mod", $.l(async (V3952, V3953) => {
    let w$;
    return $.b(shen$2emodh$c.f, V3952, (w$ = $.t(shen$2emultiples$c.f(V3952, $.r([V3953])))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.multiples", $.l((V3958, V3959) => $.isCons(V3959) && $.asNumber(V3959.head) > $.asNumber(V3958) ? $.asCons(V3959).tail : $.isCons(V3959) ? $.b(shen$2emultiples$c.f, V3958, $.r([2 * $.asNumber(V3959.head)], V3959)) : $.raise("implementation error in shen.multiples")));
  $.d("shen.modh", $.l(async (V3966, V3967) => {
    let w$;
    return 0 === V3966 ? 0 : null === V3967 ? V3966 : $.isCons(V3967) && $.asNumber(V3967.head) > $.asNumber(V3966) ? $.asJsBool((w$ = $.t(empty$3f$c.f($.asCons(V3967).tail))) instanceof Promise ? await w$ : w$) ? V3966 : $.b(shen$2emodh$c.f, V3966, $.asCons(V3967).tail) : $.isCons(V3967) ? $.b(shen$2emodh$c.f, $.asNumber(V3966) - $.asNumber(V3967.head), V3967) : $.raise("implementation error in shen.modh");
  }));
  $.d("hdstr", $.l(V3981 => pos$c.f(V3981, 0)));
  $.d("reverse", $.l(V3990 => $.b(shen$2ereverse$2dhelp$c.f, V3990, null)));
  $.d("shen.reverse-help", $.l((V3995, V3996) => null === V3995 ? V3996 : $.isCons(V3995) ? $.b(shen$2ereverse$2dhelp$c.f, V3995.tail, $.r([V3995.head], V3996)) : $.raise("attempt to reverse a non-list\n")));
  $.d("not", $.l(V4007 => $.asJsBool(V4007) ? false$s : true$s));
  $.d("explode", $.l(async V4016 => {
    let w$;
    return $.b(shen$2eexplode$2dh$c.f, (w$ = $.t(shen$2eapp$c.f(V4016, "", shen$2ea$s))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.explode-h", $.l(async V4019 => {
    let w$;
    return "" === V4019 ? null : $.asJsBool((w$ = $.t(shen$2e$2bstring$3f$c.f(V4019))) instanceof Promise ? await w$ : w$) ? $.r([(w$ = $.t(hdstr$c.f(V4019))) instanceof Promise ? await w$ : w$], (w$ = $.t(shen$2eexplode$2dh$c.f($.asNeString(V4019).substring(1)))) instanceof Promise ? await w$ : w$) : $.raise("implementation error in explode-h");
  }));
  $.d("map", $.l((V4024, V4025) => $.b(shen$2emap$2dh$c.f, V4024, V4025, null)));
  $.d("shen.map-h", $.l(async (V4026, V4027, V4028) => {
    let w$;
    return null === V4027 ? $.b(reverse$c.f, V4028) : $.isCons(V4027) ? $.b(shen$2emap$2dh$c.f, V4026, V4027.tail, $.r([(w$ = $.t(V4026(V4027.head))) instanceof Promise ? await w$ : w$], V4028)) : $.b(shen$2ef$2derror$c.f, shen$2emap$2dh$s);
  }));
  $.d("length", $.l(V4029 => $.b(shen$2elength$2dh$c.f, V4029, 0)));
  $.d("shen.length-h", $.l((V4034, V4035) => null === V4034 ? V4035 : $.b(shen$2elength$2dh$c.f, $.asCons(V4034).tail, $.asNumber(V4035) + 1)));
  $.d("integer?", $.l(async V4049 => {
    let w$, W4050$t0;
    return $.asShenBool($.isNumber(V4049) && $.asJsBool((W4050$t0 = (w$ = $.t(shen$2eabs$c.f(V4049))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2einteger$2dtest$3f$c.f(W4050$t0, (w$ = $.t(shen$2emagless$c.f(W4050$t0, 1))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
  }));
  $.d("shen.abs", $.l(V4051 => $.asNumber(V4051) > 0 ? V4051 : 0 - $.asNumber(V4051)));
  $.d("shen.magless", $.l((V4052, V4053) => {
    let W4054$t0;
    return (W4054$t0 = $.asNumber(V4053) * 2, $.asNumber(W4054$t0) > $.asNumber(V4052) ? V4053 : $.b(shen$2emagless$c.f, V4052, W4054$t0));
  }));
  $.d("shen.integer-test?", $.l((V4058, V4059) => {
    let W4060$t0;
    return 0 === V4058 ? true$s : 1 > $.asNumber(V4058) ? false$s : (W4060$t0 = $.asNumber(V4058) - $.asNumber(V4059), 0 > $.asNumber(W4060$t0) ? $.b(integer$3f$c.f, V4058) : $.b(shen$2einteger$2dtest$3f$c.f, W4060$t0, V4059));
  }));
  $.d("bound?", $.l(async V4076 => {
    let w$, W4077$t0;
    return $.asShenBool($.asJsBool((w$ = $.t(symbol$3f$c.f(V4076))) instanceof Promise ? await w$ : w$) && $.asJsBool((W4077$t0 = (() => {
      try {
        return $.valueOf($.nameOf(V4076));
      } catch (Z4078) {
        return shen$2ethis$2dsymbol$2dis$2dunbound$s;
      }
    })(), W4077$t0 === shen$2ethis$2dsymbol$2dis$2dunbound$s ? false$s : true$s)));
  }));
  $.d("fail", $.l(() => shen$2efail$21$s));
  $.d("shen.dict", $.l(async V4162 => {
    let w$, W4163$t0, W4164$t1, W4165$t2, W4166$t3, W4167$t4;
    return $.asNumber(V4162) < 1 ? $.raise("invalid initial dict size: " + $.asString((w$ = $.t(shen$2eapp$c.f(V4162, "", shen$2es$s))) instanceof Promise ? await w$ : w$)) : (W4163$t0 = absvector$c.f(3 + $.asNumber(V4162)), (W4164$t1 = address$2d$3e$c.f(W4163$t0, 0, shen$2edictionary$s), (W4165$t2 = address$2d$3e$c.f(W4163$t0, 1, V4162), (W4166$t3 = address$2d$3e$c.f(W4163$t0, 2, 0), (W4167$t4 = (w$ = $.t(shen$2efillvector$c.f(W4163$t0, 3, 2 + $.asNumber(V4162), null))) instanceof Promise ? await w$ : w$, W4163$t0)))));
  }));
  $.d("shen.dict-capacity", $.l(V4170 => $.b($3c$2daddress$c.f, V4170, 1)));
  $.d("shen.dict-count", $.l(V4171 => $.b($3c$2daddress$c.f, V4171, 2)));
  $.d("shen.dict-count->", $.l((V4172, V4173) => address$2d$3e$c.f(V4172, 2, V4173)));
  $.d("shen.<-dict-bucket", $.l((V4174, V4175) => $.b($3c$2daddress$c.f, V4174, 3 + $.asNumber(V4175))));
  $.d("shen.dict-bucket->", $.l((V4176, V4177, V4178) => address$2d$3e$c.f(V4176, 3 + $.asNumber(V4177), V4178)));
  $.d("shen.dict-update-count", $.l(async (V4179, V4180, V4181) => {
    let w$, W4182$t0;
    return (W4182$t0 = $.asNumber((w$ = $.t(length$c.f(V4181))) instanceof Promise ? await w$ : w$) - $.asNumber((w$ = $.t(length$c.f(V4180))) instanceof Promise ? await w$ : w$), $.b(shen$2edict$2dcount$2d$3e$c.f, V4179, $.asNumber(W4182$t0) + $.asNumber((w$ = $.t(shen$2edict$2dcount$c.f(V4179))) instanceof Promise ? await w$ : w$)));
  }));
  $.d("shen.dict->", $.l(async (V4183, V4184, V4185) => {
    let w$, W4186$t0, W4187$t1, W4188$t2, W4189$t3, W4190$t4;
    return (W4186$t0 = (w$ = $.t(hash$c.f(V4184, (w$ = $.t(shen$2edict$2dcapacity$c.f(V4183))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, (W4187$t1 = (w$ = $.t(shen$2e$3c$2ddict$2dbucket$c.f(V4183, W4186$t0))) instanceof Promise ? await w$ : w$, (W4188$t2 = (w$ = $.t(shen$2eassoc$2dset$c.f(V4184, V4185, W4187$t1))) instanceof Promise ? await w$ : w$, (W4189$t3 = (w$ = $.t(shen$2edict$2dbucket$2d$3e$c.f(V4183, W4186$t0, W4188$t2))) instanceof Promise ? await w$ : w$, (W4190$t4 = (w$ = $.t(shen$2edict$2dupdate$2dcount$c.f(V4183, W4187$t1, W4188$t2))) instanceof Promise ? await w$ : w$, V4185)))));
  }));
  $.d("shen.<-dict", $.l(async (V4191, V4192) => {
    let w$, W4193$t0, W4194$t1, W4195$t2;
    return (W4193$t0 = (w$ = $.t(hash$c.f(V4192, (w$ = $.t(shen$2edict$2dcapacity$c.f(V4191))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, (W4194$t1 = (w$ = $.t(shen$2e$3c$2ddict$2dbucket$c.f(V4191, W4193$t0))) instanceof Promise ? await w$ : w$, (W4195$t2 = (w$ = $.t(assoc$c.f(V4192, W4194$t1))) instanceof Promise ? await w$ : w$, $.asJsBool((w$ = $.t(empty$3f$c.f(W4195$t2))) instanceof Promise ? await w$ : w$) ? $.raise("value " + $.asString((w$ = $.t(shen$2eapp$c.f(V4192, " not found in dict\n", shen$2ea$s))) instanceof Promise ? await w$ : w$)) : $.asCons(W4195$t2).tail)));
  }));
  $.d("shen.assoc->", $.l((V2633, V2634, V2635) => null === V2635 ? $.r([$.r([V2633], V2634)]) : $.isCons(V2635) && ($.isCons(V2635.head) && $.equate(V2633, $.asCons(V2635.head).head)) ? $.r([$.r([$.asCons($.asCons(V2635).head).head], V2634)], $.asCons(V2635).tail) : $.isCons(V2635) ? $.r([V2635.head], $.t(shen$2eassoc$2d$3e$c.f(V2633, V2634, V2635.tail))) : $.raise("implementation error in shen.assoc->")));
  $.d("shen.alpha?", $.l(async V2887 => {
    let w$;
    return $.asShenBool($.asJsBool((w$ = $.t(shen$2elowercase$3f$c.f(V2887))) instanceof Promise ? await w$ : w$) || ($.asJsBool((w$ = $.t(shen$2euppercase$3f$c.f(V2887))) instanceof Promise ? await w$ : w$) || $.asJsBool((w$ = $.t(shen$2emisc$3f$c.f(V2887))) instanceof Promise ? await w$ : w$)));
  }));
  $.d("shen.lowercase?", $.l(V2888 => $.asShenBool($.asNumber(V2888) >= 97 && $.asNumber(V2888) <= 122)));
  $.d("shen.uppercase?", $.l(V2889 => $.asShenBool($.asNumber(V2889) >= 65 && $.asNumber(V2889) <= 90)));
  $.d("shen.misc?", $.l(V2890 => $.b(element$3f$c.f, V2890, $.r([61, 45, 42, 47, 43, 95, 63, 36, 33, 64, 126, 46, 62, 60, 38, 37, 39, 35, 96]))));
  $.d("shen.digit?", $.l(V2915 => $.asShenBool($.asNumber(V2915) >= 48 && $.asNumber(V2915) <= 57)));
  $.d("fn", $.l(async V3229 => {
    let w$;
    return ((w$ = $.t(arity$c.f(V3229))) instanceof Promise ? await w$ : w$) === 0 ? $.b(V3229) : await (async () => {
      let w$;
      try {
        return (w$ = $.t(get$c.f(V3229, shen$2elambda$2dform$s, $2aproperty$2dvector$2a$c.get()))) instanceof Promise ? await w$ : w$;
      } catch (Z3230) {
        return $.raise("fn: " + $.asString((w$ = $.t(shen$2eapp$c.f(V3229, " is undefined\n", shen$2ea$s))) instanceof Promise ? await w$ : w$));
      }
    })();
  }));
  $.d("shen.pvar?", $.l(async V2087 => $.asShenBool($.isArray(V2087) && await (async () => {
    let w$;
    try {
      return (w$ = $.t($3c$2daddress$c.f(V2087, 0))) instanceof Promise ? await w$ : w$;
    } catch (Z2088) {
      return shen$2enot$2dpvar$s;
    }
  })() === shen$2epvar$s)));
  $.d("shen.lazyderef", $.l((V2089, V2090) => {
    let W2091$t0;
    return $.asJsBool($.t(shen$2epvar$3f$c.f(V2089))) ? (W2091$t0 = $.t($3c$2daddress$c.f(V2090, $.t($3c$2daddress$c.f(V2089, 1)))), W2091$t0 === shen$2e$2dnull$2d$s ? V2089 : $.b(shen$2elazyderef$c.f, W2091$t0, V2090)) : V2089;
  }));
  $.d("shen.deref", $.l((V2092, V2093) => {
    let W2094$t0;
    return $.isCons(V2092) ? $.r([$.t(shen$2ederef$c.f(V2092.head, V2093))], $.t(shen$2ederef$c.f(V2092.tail, V2093))) : $.asJsBool($.t(shen$2epvar$3f$c.f(V2092))) ? (W2094$t0 = $.t($3c$2daddress$c.f(V2093, $.t($3c$2daddress$c.f(V2092, 1)))), W2094$t0 === shen$2e$2dnull$2d$s ? V2092 : $.b(shen$2ederef$c.f, W2094$t0, V2093)) : V2092;
  }));
  $.d("shen.bind!", $.l(async (V2095, V2096, V2097, V2098) => {
    let w$, W2099$t0, W2100$t1;
    return (W2099$t0 = (w$ = $.t(shen$2ebindv$c.f(V2095, V2096, V2097))) instanceof Promise ? await w$ : w$, (W2100$t1 = (w$ = $.t(thaw$c.f(V2098))) instanceof Promise ? await w$ : w$, W2100$t1 === false$s ? $.b(shen$2eunwind$c.f, V2095, V2097, W2100$t1) : W2100$t1));
  }));
  $.d("shen.bindv", $.l((V2101, V2102, V2103) => address$2d$3e$c.f(V2103, $.t($3c$2daddress$c.f(V2101, 1)), V2102)));
  $.d("shen.unwind", $.l((V2104, V2105, V2106) => (address$2d$3e$c.f(V2105, $.t($3c$2daddress$c.f(V2104, 1)), shen$2e$2dnull$2d$s), V2106)));
  $.d("shen.gc", $.l(async (V2118, V2119) => {
    let w$, W2120$t0;
    return V2119 === false$s ? (W2120$t0 = (w$ = $.t(shen$2eticket$2dnumber$c.f(V2118))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2edecrement$2dticket$c.f(W2120$t0, V2118))) instanceof Promise ? await w$ : w$, V2119)) : V2119;
  }));
  $.d("shen.decrement-ticket", $.l((V2121, V2122) => address$2d$3e$c.f(V2122, 1, $.asNumber(V2121) - 1)));
  $.d("shen.newpv", $.l(async V2123 => {
    let w$, W2124$t0, W2125$t1, W2126$t2;
    return (W2124$t0 = (w$ = $.t(shen$2eticket$2dnumber$c.f(V2123))) instanceof Promise ? await w$ : w$, (W2125$t1 = (w$ = $.t(shen$2emake$2dprolog$2dvariable$c.f(W2124$t0))) instanceof Promise ? await w$ : w$, (W2126$t2 = (w$ = $.t(shen$2enextticket$c.f(V2123, W2124$t0))) instanceof Promise ? await w$ : w$, W2125$t1)));
  }));
  $.d("shen.ticket-number", $.l(V2127 => $.b($3c$2daddress$c.f, V2127, 1)));
  $.d("shen.nextticket", $.l((V2128, V2129) => {
    let W2130$t0;
    return (W2130$t0 = address$2d$3e$c.f(V2128, V2129, shen$2e$2dnull$2d$s), address$2d$3e$c.f(W2130$t0, 1, $.asNumber(V2129) + 1));
  }));
  $.d("shen.make-prolog-variable", $.l(V2131 => address$2d$3e$c.f(address$2d$3e$c.f(absvector$c.f(2), 0, shen$2epvar$s), 1, V2131)));
  $.d("shen.pvar", $.l(async V2132 => {
    let w$;
    return "Var" + $.asString((w$ = $.t(shen$2eapp$c.f((w$ = $.t($3c$2daddress$c.f(V2132, 1))) instanceof Promise ? await w$ : w$, "", shen$2ea$s))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.lzy=!", $.l(async (V2145, V2146, V2147, V2148) => {
    let w$;
    return $.equate(V2145, V2146) ? $.b(thaw$c.f, V2148) : $.asJsBool((w$ = $.t(shen$2epvar$3f$c.f(V2145))) instanceof Promise ? await w$ : w$) && !$.asJsBool((w$ = $.t(shen$2eoccurs$2dcheck$3f$c.f(V2145, (w$ = $.t(shen$2ederef$c.f(V2146, V2147))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$) ? $.b(shen$2ebind$21$c.f, V2145, V2146, V2147, V2148) : $.asJsBool((w$ = $.t(shen$2epvar$3f$c.f(V2146))) instanceof Promise ? await w$ : w$) && !$.asJsBool((w$ = $.t(shen$2eoccurs$2dcheck$3f$c.f(V2146, (w$ = $.t(shen$2ederef$c.f(V2145, V2147))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$) ? $.b(shen$2ebind$21$c.f, V2146, V2145, V2147, V2148) : $.isCons(V2145) && $.isCons(V2146) ? $.b(shen$2elzy$3d$21$c.f, (w$ = $.t(shen$2elazyderef$c.f($.asCons(V2145).head, V2147))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2elazyderef$c.f($.asCons(V2146).head, V2147))) instanceof Promise ? await w$ : w$, V2147, $.l(async () => {
      let w$;
      return $.b(shen$2elzy$3d$21$c.f, (w$ = $.t(shen$2elazyderef$c.f($.asCons(V2145).tail, V2147))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2elazyderef$c.f($.asCons(V2146).tail, V2147))) instanceof Promise ? await w$ : w$, V2147, V2148);
    })) : false$s;
  }));
  $.d("shen.occurs-check?", $.l((V2169, V2170) => $.equate(V2169, V2170) ? true$s : $.isCons(V2170) ? $.asShenBool($.asJsBool($.t(shen$2eoccurs$2dcheck$3f$c.f(V2169, V2170.head))) || $.asJsBool($.t(shen$2eoccurs$2dcheck$3f$c.f(V2169, V2170.tail)))) : false$s));
  $.d("is!", $.l(async (V2204, V2205, V2206, V2207, V2208, V2209) => {
    let w$;
    return $.b(shen$2elzy$3d$21$c.f, (w$ = $.t(shen$2elazyderef$c.f(V2204, V2206))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2elazyderef$c.f(V2205, V2206))) instanceof Promise ? await w$ : w$, V2206, V2209);
  }));
  $.d("shen.f-error", $.l(V => $.raise($.show(V) + ": partial function or unhandled case")));
  $.d("shen.app", $.l(async (V6854, V6855, V6856) => {
    let w$;
    return $.asString((w$ = $.t(shen$2earg$2d$3estr$c.f(V6854, V6856))) instanceof Promise ? await w$ : w$) + $.asString(V6855);
  }));
  $.d("shen.arg->str", $.l(async (V6860, V6861) => {
    let w$;
    return $.equate(V6860, (w$ = $.t(fail$c.f())) instanceof Promise ? await w$ : w$) ? "..." : $.asJsBool((w$ = $.t(shen$2elist$3f$c.f(V6860))) instanceof Promise ? await w$ : w$) ? $.b(shen$2elist$2d$3estr$c.f, V6860, V6861) : $.isString(V6860) ? $.b(shen$2estr$2d$3estr$c.f, V6860, V6861) : $.isArray(V6860) ? $.b(shen$2evector$2d$3estr$c.f, V6860, V6861) : $.b(shen$2eatom$2d$3estr$c.f, V6860);
  }));
  $.d("shen.list->str", $.l(async (V6862, V6863) => {
    let w$;
    return shen$2er$s === V6863 ? $.b($40s$c.f, "(", (w$ = $.t($40s$c.f((w$ = $.t(shen$2eiter$2dlist$c.f(V6862, shen$2er$s, (w$ = $.t(shen$2emaxseq$c.f())) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, ")"))) instanceof Promise ? await w$ : w$) : $.b($40s$c.f, "[", (w$ = $.t($40s$c.f((w$ = $.t(shen$2eiter$2dlist$c.f(V6862, V6863, (w$ = $.t(shen$2emaxseq$c.f())) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, "]"))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.maxseq", $.l(() => $2amaximum$2dprint$2dsequence$2dsize$2a$c.get()));
  $.d("shen.iter-list", $.l(async (V6874, V6875, V6876) => {
    let w$;
    return null === V6874 ? "" : 0 === V6876 ? "... etc" : $.isCons(V6874) && null === V6874.tail ? $.b(shen$2earg$2d$3estr$c.f, $.asCons(V6874).head, V6875) : $.isCons(V6874) ? $.b($40s$c.f, (w$ = $.t(shen$2earg$2d$3estr$c.f(V6874.head, V6875))) instanceof Promise ? await w$ : w$, (w$ = $.t($40s$c.f(" ", (w$ = $.t(shen$2eiter$2dlist$c.f(V6874.tail, V6875, $.asNumber(V6876) - 1))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$) : $.b($40s$c.f, "|", (w$ = $.t($40s$c.f(" ", (w$ = $.t(shen$2earg$2d$3estr$c.f(V6874, V6875))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.str->str", $.l(async (V6879, V6880) => {
    let w$;
    return shen$2ea$s === V6880 ? V6879 : $.b($40s$c.f, String.fromCharCode(34), (w$ = $.t($40s$c.f(V6879, String.fromCharCode(34)))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.vector->str", $.l(async (V6881, V6882) => {
    let w$;
    return $.asJsBool((w$ = $.t(shen$2eprint$2dvector$3f$c.f(V6881))) instanceof Promise ? await w$ : w$) ? $.b((w$ = $.t(fn$c.f((w$ = $.t($3c$2daddress$c.f(V6881, 0))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, V6881) : $.asJsBool((w$ = $.t(vector$3f$c.f(V6881))) instanceof Promise ? await w$ : w$) ? $.b($40s$c.f, "<", (w$ = $.t($40s$c.f((w$ = $.t(shen$2eiter$2dvector$c.f(V6881, 1, V6882, (w$ = $.t(shen$2emaxseq$c.f())) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, ">"))) instanceof Promise ? await w$ : w$) : $.b($40s$c.f, "<", (w$ = $.t($40s$c.f("<", (w$ = $.t($40s$c.f((w$ = $.t(shen$2eiter$2dvector$c.f(V6881, 0, V6882, (w$ = $.t(shen$2emaxseq$c.f())) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, ">>"))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.empty-absvector?", $.l(V6883 => $.asShenBool($.equate(V6883, shen$2e$2aempty$2dabsvector$2a$c.get()))));
  $.d("shen.print-vector?", $.l(async V6884 => {
    let w$, W6885$t0;
    return $.asShenBool(!$.asJsBool((w$ = $.t(shen$2eempty$2dabsvector$3f$c.f(V6884))) instanceof Promise ? await w$ : w$) && $.asJsBool((W6885$t0 = (w$ = $.t($3c$2daddress$c.f(V6884, 0))) instanceof Promise ? await w$ : w$, $.asShenBool(W6885$t0 === shen$2etuple$s || (W6885$t0 === shen$2epvar$s || (W6885$t0 === shen$2edictionary$s || !$.isNumber(W6885$t0) && $.asJsBool((w$ = $.t(shen$2efbound$3f$c.f(W6885$t0))) instanceof Promise ? await w$ : w$)))))));
  }));
  $.d("shen.fbound?", $.l(async V6886 => {
    let w$;
    return $.asShenBool(!(((w$ = $.t(arity$c.f(V6886))) instanceof Promise ? await w$ : w$) === -1));
  }));
  $.d("shen.tuple", $.l(async V6887 => {
    let w$;
    return "(@p " + $.asString((w$ = $.t(shen$2eapp$c.f((w$ = $.t($3c$2daddress$c.f(V6887, 1))) instanceof Promise ? await w$ : w$, " " + $.asString((w$ = $.t(shen$2eapp$c.f((w$ = $.t($3c$2daddress$c.f(V6887, 2))) instanceof Promise ? await w$ : w$, ")", shen$2es$s))) instanceof Promise ? await w$ : w$), shen$2es$s))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.dictionary", $.l(V6888 => "(dict ...)"));
  $.d("shen.iter-vector", $.l(async (V6895, V6896, V6897, V6898) => {
    let w$, W6899$t0, W6901$t1;
    return 0 === V6898 ? "... etc" : (W6899$t0 = await (async () => {
      let w$;
      try {
        return (w$ = $.t($3c$2daddress$c.f(V6895, V6896))) instanceof Promise ? await w$ : w$;
      } catch (Z6900) {
        return shen$2eout$2dof$2dbounds$s;
      }
    })(), (W6901$t1 = await (async () => {
      let w$;
      try {
        return (w$ = $.t($3c$2daddress$c.f(V6895, $.asNumber(V6896) + 1))) instanceof Promise ? await w$ : w$;
      } catch (Z6902) {
        return shen$2eout$2dof$2dbounds$s;
      }
    })(), W6899$t0 === shen$2eout$2dof$2dbounds$s ? "" : W6901$t1 === shen$2eout$2dof$2dbounds$s ? $.b(shen$2earg$2d$3estr$c.f, W6899$t0, V6897) : $.b($40s$c.f, (w$ = $.t(shen$2earg$2d$3estr$c.f(W6899$t0, V6897))) instanceof Promise ? await w$ : w$, (w$ = $.t($40s$c.f(" ", (w$ = $.t(shen$2eiter$2dvector$c.f(V6895, $.asNumber(V6896) + 1, V6897, $.asNumber(V6898) - 1))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
  }));
  $.d("shen.atom->str", $.l(V6903 => (() => {
    try {
      return $.show(V6903);
    } catch (Z6904) {
      return $.b(shen$2efunexstring$c.f);
    }
  })()));
  $.d("shen.funexstring", $.l(async () => {
    let w$;
    return $.b($40s$c.f, "\u0010", (w$ = $.t($40s$c.f("f", (w$ = $.t($40s$c.f("u", (w$ = $.t($40s$c.f("n", (w$ = $.t($40s$c.f("e", (w$ = $.t($40s$c.f((w$ = $.t(shen$2earg$2d$3estr$c.f((w$ = $.t(gensym$c.f($.symbolOf("x")))) instanceof Promise ? await w$ : w$, shen$2ea$s))) instanceof Promise ? await w$ : w$, "\u0011"))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$);
  }));
  $.d("shen.list?", $.l(async V6905 => {
    let w$;
    return $.asShenBool($.asJsBool((w$ = $.t(empty$3f$c.f(V6905))) instanceof Promise ? await w$ : w$) || $.isCons(V6905));
  }));
  $.d("prolog-memory", $.l(V910 => $.asNumber(V910) < 0 ? shen$2e$2aprolog$2dmemory$2a$c.get() : $.asJsBool($.t(integer$3f$c.f(V910))) ? shen$2e$2aprolog$2dmemory$2a$c.set(V910) : $.raise("prolog memory expects an integer value\n")));
  $.d("arity", $.l(async V911 => await (async () => {
    let w$;
    try {
      return (w$ = $.t(get$c.f(V911, arity$s, $2aproperty$2dvector$2a$c.get()))) instanceof Promise ? await w$ : w$;
    } catch (Z912) {
      return -1;
    }
  })()));
  $.d("shen.initialise-arity-table", $.l(V915 => {
    let W916$t0;
    return null === V915 ? null : $.isCons(V915) && $.isCons(V915.tail) ? (W916$t0 = $.t(put$c.f($.asCons(V915).head, arity$s, $.asCons($.asCons(V915).tail).head, $2aproperty$2dvector$2a$c.get())), $.b(shen$2einitialise$2darity$2dtable$c.f, $.asCons($.asCons(V915).tail).tail)) : $.raise("implementation error in shen.initialise-arity-table");
  }));
  $.d("shen.set-lambda-form-entry", $.l(V924 => $.isCons(V924) ? $.b(put$c.f, V924.head, shen$2elambda$2dform$s, V924.tail, $2aproperty$2dvector$2a$c.get()) : $.b(shen$2ef$2derror$c.f, shen$2eset$2dlambda$2dform$2dentry$s)));
  $.d("shen.initialise-environment", $.l(async () => {
    let w$;
    return (shen$2e$2ahistory$2a$c.set(null), (shen$2e$2atc$2a$c.set(false$s), ($2aproperty$2dvector$2a$c.set((w$ = $.t(shen$2edict$c.f(20000))) instanceof Promise ? await w$ : w$), ($2amacros$2a$c.set(null), (shen$2e$2agensym$2a$c.set(0), (shen$2e$2atracking$2a$c.set(null), (shen$2e$2aprofiled$2a$c.set(null), (shen$2e$2aspecial$2a$c.set($.r([$40p$s, $40s$s, $40v$s, cons$s, lambda$s, let$s, where$s, set$s, open$s, input$2b$s, type$s])), (shen$2e$2aextraspecial$2a$c.set(null), (shen$2e$2aspy$2a$c.set(false$s), (shen$2e$2adatatypes$2a$c.set(null), (shen$2e$2aalldatatypes$2a$c.set(null), (shen$2e$2ashen$2dtype$2dtheory$2denabled$3f$2a$c.set(true$s), (shen$2e$2apackage$2a$c.set(null$s), (shen$2e$2asynonyms$2a$c.set(null), (shen$2e$2asystem$2a$c.set(null), (shen$2e$2aoccurs$2a$c.set(true$s), (shen$2e$2afactorise$3f$2a$c.set(false$s), (shen$2e$2amaxinferences$2a$c.set(1000000), ($2amaximum$2dprint$2dsequence$2dsize$2a$c.set(20), (shen$2e$2acall$2a$c.set(0), (shen$2e$2ainfs$2a$c.set(0), ($2ahush$2a$c.set(false$s), (shen$2e$2aoptimise$2a$c.set(false$s), ($2aversion$2a$c.set("41.2"), (shen$2e$2anames$2a$c.set(null), (shen$2e$2astep$2a$c.set(false$s), (shen$2e$2ait$2a$c.set(""), (shen$2e$2aresidue$2a$c.set(null), ($2aabsolute$2a$c.set(null), (shen$2e$2aprolog$2dmemory$2a$c.set(1000), (shen$2e$2aloading$3f$2a$c.set(false$s), (shen$2e$2auserdefs$2a$c.set(null), (shen$2e$2ademodulation$2dfunction$2a$c.set($.l(X => X)), (shen$2e$2acustom$2dpattern$2dcompiler$2a$c.set(false$s), (shen$2e$2acustom$2dpattern$2dreducer$2a$c.set(false$s), (!$.asJsBool((w$ = $.t(bound$3f$c.f($2ahome$2ddirectory$2a$s))) instanceof Promise ? await w$ : w$) ? $2ahome$2ddirectory$2a$c.set("") : shen$2eskip$s, (!$.asJsBool((w$ = $.t(bound$3f$c.f($2asterror$2a$s))) instanceof Promise ? await w$ : w$) ? $2asterror$2a$c.set($2astoutput$2a$c.get()) : shen$2eskip$s, ((w$ = $.t(prolog$2dmemory$c.f(10000))) instanceof Promise ? await w$ : w$, (shen$2e$2aloading$3f$2a$c.set(false$s), ((w$ = $.t(shen$2einitialise$2darity$2dtable$c.f($.r([absvector$3f$s, 1, absvector$s, 1, address$2d$3e$s, 3, and$s, 2, append$s, 2, arity$s, 1, assoc$s, 2, boolean$3f$s, 1, bound$3f$s, 1, concat$s, 2, cons$s, 2, cons$3f$s, 1, cn$s, 2, close$s, 1, do$s, 2, element$3f$s, 2, empty$3f$s, 1, error$2dto$2dstring$s, 1, explode$s, 1, fail$s, 0, freeze$s, 1, fn$s, 1, gensym$s, 1, get$s, 3, get$2dtime$s, 1, address$2d$3e$s, 3, $3c$2daddress$s, 2, $3e$s, 2, $3e$3d$s, 2, $3d$s, 2, hash$s, 2, hd$s, 1, hdstr$s, 1, if$s, 3, integer$3f$s, 1, intern$s, 1, is$21$s, 6, length$s, 1, $3c$s, 2, $3c$3d$s, 2, vector$s, 1, map$s, 2, not$s, 1, n$2d$3estring$s, 1, number$3f$s, 1, open$s, 2, or$s, 2, pos$s, 2, prolog$2dmemory$s, 1, put$s, 4, read$2dbyte$s, 1, shen$2eread$2dunit$2dstring$s, 1, reverse$s, 1, set$s, 2, simple$2derror$s, 1, str$s, 1, string$2d$3en$s, 1, string$3f$s, 1, symbol$3f$s, 1, tl$s, 1, thaw$s, 1, tlstr$s, 1, trap$2derror$s, 2, type$s, 2, vector$s, 1, vector$3f$s, 1, value$s, 1, write$2dbyte$s, 2, $2b$s, 2, $2a$s, 2, $2f$s, 2, $2d$s, 2, $40s$s, 2])))) instanceof Promise ? await w$ : w$, ((w$ = $.t(put$c.f(shen$s, shen$2eexternal$2dsymbols$s, $.r([$2astinput$2a$s, $2astoutput$2a$s, $40s$s, $3d$s, $3e$3d$s, $3e$s, $2d$s, $2f$s, $2a$s, $2b$s, $3c$3d$s, $3c$s, write$2dbyte$s, value$s, vector$s, vector$3f$s, type$s, trap$2derror$s, thaw$s, tl$s, tlstr$s, symbol$3f$s, string$3f$s, string$2d$3en$s, simple$2derror$s, set$s, str$s, reverse$s, read$2dbyte$s, put$s, prolog$2dmemory$s, pos$s, or$s, open$s, n$2d$3estring$s, number$3f$s, not$s, map$s, length$s, let$s, lambda$s, intern$s, integer$3f$s, is$21$s, if$s, hd$s, hdstr$s, hash$s, get$s, get$2dtime$s, gensym$s, fn$s, freeze$s, fail$s, explode$s, error$2dto$2dstring$s, empty$3f$s, element$3f$s, do$s, defun$s, cn$s, cons$3f$s, cons$s, cond$s, concat$s, close$s, bound$3f$s, boolean$3f$s, assoc$s, arity$s, append$s, and$s, $3c$2daddress$s, address$2d$3e$s, absvector$3f$s, absvector$s]), $2aproperty$2dvector$2a$c.get()))) instanceof Promise ? await w$ : w$, shen$2e$2aempty$2dabsvector$2a$c.set(absvector$c.f(0))))))))))))))))))))))))))))))))))))))))))));
  }));
  $.d("shen.initialise-signedfuncs", $.l(async () => {
    let w$;
    return (shen$2e$2asigf$2a$c.set(null), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(abort$s, $.l(async (V5951, B5947, L5948, Key5949, C5950) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5947))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5947, (w$ = $.t(is$21$c.f(V5951, $.r([$2d$2d$3e$s, A$t0]), B5947, L5948, Key5949, C5950))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(absolute$s, $.l((V5956, B5952, L5953, Key5954, C5955) => $.b(is$21$c.f, V5956, $.r([string$s, $2d$2d$3e$s, $.r([list$s, string$s])]), B5952, L5953, Key5954, C5955)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(absvector$3f$s, $.l(async (V5961, B5957, L5958, Key5959, C5960) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5957))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5957, (w$ = $.t(is$21$c.f(V5961, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B5957, L5958, Key5959, C5960))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(adjoin$s, $.l(async (V5966, B5962, L5963, Key5964, C5965) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5962))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5962, (w$ = $.t(is$21$c.f(V5966, $.r([A$t0, $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B5962, L5963, Key5964, C5965))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(and$s, $.l((V5971, B5967, L5968, Key5969, C5970) => $.b(is$21$c.f, V5971, $.r([boolean$s, $2d$2d$3e$s, $.r([boolean$s, $2d$2d$3e$s, boolean$s])]), B5967, L5968, Key5969, C5970)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2eapp$s, $.l(async (V5976, B5972, L5973, Key5974, C5975) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5972))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5972, (w$ = $.t(is$21$c.f(V5976, $.r([A$t0, $2d$2d$3e$s, $.r([string$s, $2d$2d$3e$s, $.r([symbol$s, $2d$2d$3e$s, string$s])])]), B5972, L5973, Key5974, C5975))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(append$s, $.l(async (V5981, B5977, L5978, Key5979, C5980) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5977))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5977, (w$ = $.t(is$21$c.f(V5981, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B5977, L5978, Key5979, C5980))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(arity$s, $.l(async (V5986, B5982, L5983, Key5984, C5985) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5982))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5982, (w$ = $.t(is$21$c.f(V5986, $.r([A$t0, $2d$2d$3e$s, number$s]), B5982, L5983, Key5984, C5985))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(assoc$s, $.l(async (V5991, B5987, L5988, Key5989, C5990) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5987))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5987, (w$ = $.t(is$21$c.f(V5991, $.r([A$t0, $2d$2d$3e$s, $.r([$.r([list$s, $.r([list$s, A$t0])]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B5987, L5988, Key5989, C5990))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(atom$3f$s, $.l(async (V5996, B5992, L5993, Key5994, C5995) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5992))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5992, (w$ = $.t(is$21$c.f(V5996, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B5992, L5993, Key5994, C5995))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(boolean$3f$s, $.l(async (V6001, B5997, L5998, Key5999, C6000) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B5997))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B5997, (w$ = $.t(is$21$c.f(V6001, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B5997, L5998, Key5999, C6000))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(bootstrap$s, $.l((V6006, B6002, L6003, Key6004, C6005) => $.b(is$21$c.f, V6006, $.r([string$s, $2d$2d$3e$s, string$s]), B6002, L6003, Key6004, C6005)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(bound$3f$s, $.l((V6011, B6007, L6008, Key6009, C6010) => $.b(is$21$c.f, V6011, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6007, L6008, Key6009, C6010)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2eccons$3f$s, $.l(async (V6016, B6012, L6013, Key6014, C6015) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6012))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6012, (w$ = $.t(is$21$c.f(V6016, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, boolean$s]), B6012, L6013, Key6014, C6015))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(cd$s, $.l((V6021, B6017, L6018, Key6019, C6020) => $.b(is$21$c.f, V6021, $.r([string$s, $2d$2d$3e$s, string$s]), B6017, L6018, Key6019, C6020)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(close$s, $.l(async (V6026, B6022, L6023, Key6024, C6025) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6022))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6022, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6022))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6022, (w$ = $.t(is$21$c.f(V6026, $.r([$.r([stream$s, A$t0]), $2d$2d$3e$s, $.r([list$s, B$t1])]), B6022, L6023, Key6024, C6025))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(cn$s, $.l((V6031, B6027, L6028, Key6029, C6030) => $.b(is$21$c.f, V6031, $.r([string$s, $2d$2d$3e$s, $.r([string$s, $2d$2d$3e$s, string$s])]), B6027, L6028, Key6029, C6030)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(compile$s, $.l(async (V6036, B6032, L6033, Key6034, C6035) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6032))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6032, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6032))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6032, (w$ = $.t(is$21$c.f(V6036, $.r([$.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([str$s, $.r([list$s, A$t0]), B$t1])]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, B$t1])]), B6032, L6033, Key6034, C6035))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(cons$3f$s, $.l(async (V6041, B6037, L6038, Key6039, C6040) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6037))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6037, (w$ = $.t(is$21$c.f(V6041, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6037, L6038, Key6039, C6040))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(datatypes$s, $.l((V6046, B6042, L6043, Key6044, C6045) => $.b(is$21$c.f, V6046, $.r([$2d$2d$3e$s, $.r([list$s, symbol$s])]), B6042, L6043, Key6044, C6045)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(destroy$s, $.l((V6051, B6047, L6048, Key6049, C6050) => $.b(is$21$c.f, V6051, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6047, L6048, Key6049, C6050)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(difference$s, $.l(async (V6056, B6052, L6053, Key6054, C6055) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6052))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6052, (w$ = $.t(is$21$c.f(V6056, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B6052, L6053, Key6054, C6055))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(do$s, $.l(async (V6061, B6057, L6058, Key6059, C6060) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6057))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6057, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6057))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6057, (w$ = $.t(is$21$c.f(V6061, $.r([A$t0, $2d$2d$3e$s, $.r([B$t1, $2d$2d$3e$s, B$t1])]), B6057, L6058, Key6059, C6060))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3ce$3e$s, $.l(async (V6066, B6062, L6063, Key6064, C6065) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6062))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6062, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6062))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6062, (w$ = $.t(is$21$c.f(V6066, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([str$s, $.r([list$s, A$t0]), $.r([list$s, B$t1])])]), B6062, L6063, Key6064, C6065))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3c$21$3e$s, $.l(async (V6071, B6067, L6068, Key6069, C6070) => {
      let w$, B$t0, A$t1;
      return (B$t0 = (w$ = $.t(shen$2enewpv$c.f(B6067))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6067, (A$t1 = (w$ = $.t(shen$2enewpv$c.f(B6067))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6067, (w$ = $.t(is$21$c.f(V6071, $.r([$.r([list$s, A$t1]), $2d$2d$3e$s, $.r([str$s, $.r([list$s, B$t0]), $.r([list$s, A$t1])])]), B6067, L6068, Key6069, C6070))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3cend$3e$s, $.l(async (V6076, B6072, L6073, Key6074, C6075) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6072))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6072, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6072))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6072, (w$ = $.t(is$21$c.f(V6076, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([str$s, $.r([list$s, A$t0]), $.r([list$s, B$t1])])]), B6072, L6073, Key6074, C6075))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2eparse$2dfailure$3f$s, $.l(async (V6081, B6077, L6078, Key6079, C6080) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6077))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6077, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6077))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6077, (w$ = $.t(is$21$c.f(V6081, $.r([$.r([str$s, $.r([list$s, A$t0]), B$t1]), $2d$2d$3e$s, boolean$s]), B6077, L6078, Key6079, C6080))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2eparse$2dfailure$s, $.l(async (V6086, B6082, L6083, Key6084, C6085) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6082))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6082, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6082))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6082, (w$ = $.t(is$21$c.f(V6086, $.r([$2d$2d$3e$s, $.r([str$s, $.r([list$s, A$t0]), B$t1])]), B6082, L6083, Key6084, C6085))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2e$3c$2dout$s, $.l(async (V6091, B6087, L6088, Key6089, C6090) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6087))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6087, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6087))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6087, (w$ = $.t(is$21$c.f(V6091, $.r([$.r([str$s, $.r([list$s, A$t0]), B$t1]), $2d$2d$3e$s, B$t1]), B6087, L6088, Key6089, C6090))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2ein$2d$3e$s, $.l(async (V6096, B6092, L6093, Key6094, C6095) => {
      let w$, B$t0, A$t1;
      return (B$t0 = (w$ = $.t(shen$2enewpv$c.f(B6092))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6092, (A$t1 = (w$ = $.t(shen$2enewpv$c.f(B6092))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6092, (w$ = $.t(is$21$c.f(V6096, $.r([$.r([str$s, $.r([list$s, A$t1]), B$t0]), $2d$2d$3e$s, $.r([list$s, A$t1])]), B6092, L6093, Key6094, C6095))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2ecomb$s, $.l(async (V6101, B6097, L6098, Key6099, C6100) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6097))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6097, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6097))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6097, (w$ = $.t(is$21$c.f(V6101, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([B$t1, $2d$2d$3e$s, $.r([str$s, $.r([list$s, A$t0]), B$t1])])]), B6097, L6098, Key6099, C6100))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(element$3f$s, $.l(async (V6106, B6102, L6103, Key6104, C6105) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6102))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6102, (w$ = $.t(is$21$c.f(V6106, $.r([A$t0, $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, boolean$s])]), B6102, L6103, Key6104, C6105))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(empty$3f$s, $.l(async (V6111, B6107, L6108, Key6109, C6110) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6107))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6107, (w$ = $.t(is$21$c.f(V6111, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6107, L6108, Key6109, C6110))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(enable$2dtype$2dtheory$s, $.l((V6116, B6112, L6113, Key6114, C6115) => $.b(is$21$c.f, V6116, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6112, L6113, Key6114, C6115)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(external$s, $.l((V6121, B6117, L6118, Key6119, C6120) => $.b(is$21$c.f, V6121, $.r([symbol$s, $2d$2d$3e$s, $.r([list$s, symbol$s])]), B6117, L6118, Key6119, C6120)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(error$2dto$2dstring$s, $.l((V6126, B6122, L6123, Key6124, C6125) => $.b(is$21$c.f, V6126, $.r([exception$s, $2d$2d$3e$s, string$s]), B6122, L6123, Key6124, C6125)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(explode$s, $.l(async (V6131, B6127, L6128, Key6129, C6130) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6127))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6127, (w$ = $.t(is$21$c.f(V6131, $.r([A$t0, $2d$2d$3e$s, $.r([list$s, string$s])]), B6127, L6128, Key6129, C6130))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(factorise$s, $.l((V6136, B6132, L6133, Key6134, C6135) => $.b(is$21$c.f, V6136, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6132, L6133, Key6134, C6135)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(factorise$3f$s, $.l((V6141, B6137, L6138, Key6139, C6140) => $.b(is$21$c.f, V6141, $.r([$2d$2d$3e$s, boolean$s]), B6137, L6138, Key6139, C6140)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(fail$s, $.l((V6146, B6142, L6143, Key6144, C6145) => $.b(is$21$c.f, V6146, $.r([$2d$2d$3e$s, symbol$s]), B6142, L6143, Key6144, C6145)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(fix$s, $.l(async (V6151, B6147, L6148, Key6149, C6150) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6147))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6147, (w$ = $.t(is$21$c.f(V6151, $.r([$.r([A$t0, $2d$2d$3e$s, A$t0]), $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, A$t0])]), B6147, L6148, Key6149, C6150))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(freeze$s, $.l(async (V6156, B6152, L6153, Key6154, C6155) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6152))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6152, (w$ = $.t(is$21$c.f(V6156, $.r([A$t0, $2d$2d$3e$s, $.r([lazy$s, A$t0])]), B6152, L6153, Key6154, C6155))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(fst$s, $.l(async (V6161, B6157, L6158, Key6159, C6160) => {
      let w$, B$t0, A$t1;
      return (B$t0 = (w$ = $.t(shen$2enewpv$c.f(B6157))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6157, (A$t1 = (w$ = $.t(shen$2enewpv$c.f(B6157))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6157, (w$ = $.t(is$21$c.f(V6161, $.r([$.r([A$t1, $2a$s, B$t0]), $2d$2d$3e$s, A$t1]), B6157, L6158, Key6159, C6160))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(gensym$s, $.l((V6166, B6162, L6163, Key6164, C6165) => $.b(is$21$c.f, V6166, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6162, L6163, Key6164, C6165)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2ehds$3d$3f$s, $.l(async (V6171, B6167, L6168, Key6169, C6170) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6167))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6167, (w$ = $.t(is$21$c.f(V6171, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, boolean$s])]), B6167, L6168, Key6169, C6170))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(hush$s, $.l((V6176, B6172, L6173, Key6174, C6175) => $.b(is$21$c.f, V6176, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6172, L6173, Key6174, C6175)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(hush$3f$s, $.l((V6181, B6177, L6178, Key6179, C6180) => $.b(is$21$c.f, V6181, $.r([$2d$2d$3e$s, boolean$s]), B6177, L6178, Key6179, C6180)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3c$2dvector$s, $.l(async (V6186, B6182, L6183, Key6184, C6185) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6182))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6182, (w$ = $.t(is$21$c.f(V6186, $.r([$.r([vector$s, A$t0]), $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, A$t0])]), B6182, L6183, Key6184, C6185))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(vector$2d$3e$s, $.l(async (V6191, B6187, L6188, Key6189, C6190) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6187))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6187, (w$ = $.t(is$21$c.f(V6191, $.r([$.r([vector$s, A$t0]), $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, $.r([vector$s, A$t0])])])]), B6187, L6188, Key6189, C6190))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(vector$s, $.l(async (V6196, B6192, L6193, Key6194, C6195) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6192))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6192, (w$ = $.t(is$21$c.f(V6196, $.r([number$s, $2d$2d$3e$s, $.r([vector$s, A$t0])]), B6192, L6193, Key6194, C6195))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(get$2dtime$s, $.l((V6201, B6197, L6198, Key6199, C6200) => $.b(is$21$c.f, V6201, $.r([symbol$s, $2d$2d$3e$s, number$s]), B6197, L6198, Key6199, C6200)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(hash$s, $.l(async (V6206, B6202, L6203, Key6204, C6205) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6202))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6202, (w$ = $.t(is$21$c.f(V6206, $.r([A$t0, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, number$s])]), B6202, L6203, Key6204, C6205))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(head$s, $.l(async (V6211, B6207, L6208, Key6209, C6210) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6207))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6207, (w$ = $.t(is$21$c.f(V6211, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, A$t0]), B6207, L6208, Key6209, C6210))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(hdv$s, $.l(async (V6216, B6212, L6213, Key6214, C6215) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6212))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6212, (w$ = $.t(is$21$c.f(V6216, $.r([$.r([vector$s, A$t0]), $2d$2d$3e$s, A$t0]), B6212, L6213, Key6214, C6215))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(hdstr$s, $.l((V6221, B6217, L6218, Key6219, C6220) => $.b(is$21$c.f, V6221, $.r([string$s, $2d$2d$3e$s, string$s]), B6217, L6218, Key6219, C6220)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(if$s, $.l(async (V6226, B6222, L6223, Key6224, C6225) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6222))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6222, (w$ = $.t(is$21$c.f(V6226, $.r([boolean$s, $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, A$t0])])]), B6222, L6223, Key6224, C6225))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(in$2dpackage$s, $.l((V6231, B6227, L6228, Key6229, C6230) => $.b(is$21$c.f, V6231, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6227, L6228, Key6229, C6230)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(it$s, $.l((V6236, B6232, L6233, Key6234, C6235) => $.b(is$21$c.f, V6236, $.r([$2d$2d$3e$s, string$s]), B6232, L6233, Key6234, C6235)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(implementation$s, $.l((V6241, B6237, L6238, Key6239, C6240) => $.b(is$21$c.f, V6241, $.r([$2d$2d$3e$s, string$s]), B6237, L6238, Key6239, C6240)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(include$s, $.l((V6246, B6242, L6243, Key6244, C6245) => $.b(is$21$c.f, V6246, $.r([$.r([list$s, symbol$s]), $2d$2d$3e$s, $.r([list$s, symbol$s])]), B6242, L6243, Key6244, C6245)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(include$2dall$2dbut$s, $.l((V6251, B6247, L6248, Key6249, C6250) => $.b(is$21$c.f, V6251, $.r([$.r([list$s, symbol$s]), $2d$2d$3e$s, $.r([list$s, symbol$s])]), B6247, L6248, Key6249, C6250)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(included$s, $.l((V6256, B6252, L6253, Key6254, C6255) => $.b(is$21$c.f, V6256, $.r([$2d$2d$3e$s, $.r([list$s, symbol$s])]), B6252, L6253, Key6254, C6255)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(inferences$s, $.l((V6261, B6257, L6258, Key6259, C6260) => $.b(is$21$c.f, V6261, $.r([$2d$2d$3e$s, number$s]), B6257, L6258, Key6259, C6260)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2einsert$s, $.l(async (V6266, B6262, L6263, Key6264, C6265) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6262))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6262, (w$ = $.t(is$21$c.f(V6266, $.r([A$t0, $2d$2d$3e$s, $.r([string$s, $2d$2d$3e$s, string$s])]), B6262, L6263, Key6264, C6265))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(integer$3f$s, $.l(async (V6271, B6267, L6268, Key6269, C6270) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6267))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6267, (w$ = $.t(is$21$c.f(V6271, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6267, L6268, Key6269, C6270))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(internal$s, $.l((V6276, B6272, L6273, Key6274, C6275) => $.b(is$21$c.f, V6276, $.r([symbol$s, $2d$2d$3e$s, $.r([list$s, symbol$s])]), B6272, L6273, Key6274, C6275)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(intersection$s, $.l(async (V6281, B6277, L6278, Key6279, C6280) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6277))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6277, (w$ = $.t(is$21$c.f(V6281, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B6277, L6278, Key6279, C6280))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(language$s, $.l((V6286, B6282, L6283, Key6284, C6285) => $.b(is$21$c.f, V6286, $.r([$2d$2d$3e$s, string$s]), B6282, L6283, Key6284, C6285)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(length$s, $.l(async (V6291, B6287, L6288, Key6289, C6290) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6287))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6287, (w$ = $.t(is$21$c.f(V6291, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, number$s]), B6287, L6288, Key6289, C6290))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(limit$s, $.l(async (V6296, B6292, L6293, Key6294, C6295) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6292))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6292, (w$ = $.t(is$21$c.f(V6296, $.r([$.r([vector$s, A$t0]), $2d$2d$3e$s, number$s]), B6292, L6293, Key6294, C6295))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(lineread$s, $.l((V6301, B6297, L6298, Key6299, C6300) => $.b(is$21$c.f, V6301, $.r([$.r([stream$s, in$s]), $2d$2d$3e$s, $.r([list$s, unit$s])]), B6297, L6298, Key6299, C6300)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(load$s, $.l((V6306, B6302, L6303, Key6304, C6305) => $.b(is$21$c.f, V6306, $.r([string$s, $2d$2d$3e$s, symbol$s]), B6302, L6303, Key6304, C6305)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(map$s, $.l(async (V6311, B6307, L6308, Key6309, C6310) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6307))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6307, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6307))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6307, (w$ = $.t(is$21$c.f(V6311, $.r([$.r([A$t0, $2d$2d$3e$s, B$t1]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, B$t1])])]), B6307, L6308, Key6309, C6310))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(mapcan$s, $.l(async (V6316, B6312, L6313, Key6314, C6315) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6312))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6312, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6312))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6312, (w$ = $.t(is$21$c.f(V6316, $.r([$.r([A$t0, $2d$2d$3e$s, $.r([list$s, B$t1])]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, B$t1])])]), B6312, L6313, Key6314, C6315))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(maxinferences$s, $.l((V6321, B6317, L6318, Key6319, C6320) => $.b(is$21$c.f, V6321, $.r([number$s, $2d$2d$3e$s, number$s]), B6317, L6318, Key6319, C6320)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(n$2d$3estring$s, $.l((V6326, B6322, L6323, Key6324, C6325) => $.b(is$21$c.f, V6326, $.r([number$s, $2d$2d$3e$s, string$s]), B6322, L6323, Key6324, C6325)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(nl$s, $.l((V6331, B6327, L6328, Key6329, C6330) => $.b(is$21$c.f, V6331, $.r([number$s, $2d$2d$3e$s, number$s]), B6327, L6328, Key6329, C6330)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(not$s, $.l((V6336, B6332, L6333, Key6334, C6335) => $.b(is$21$c.f, V6336, $.r([boolean$s, $2d$2d$3e$s, boolean$s]), B6332, L6333, Key6334, C6335)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(nth$s, $.l(async (V6341, B6337, L6338, Key6339, C6340) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6337))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6337, (w$ = $.t(is$21$c.f(V6341, $.r([number$s, $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, A$t0])]), B6337, L6338, Key6339, C6340))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(number$3f$s, $.l(async (V6346, B6342, L6343, Key6344, C6345) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6342))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6342, (w$ = $.t(is$21$c.f(V6346, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6342, L6343, Key6344, C6345))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(occurrences$s, $.l(async (V6351, B6347, L6348, Key6349, C6350) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6347))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6347, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6347))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6347, (w$ = $.t(is$21$c.f(V6351, $.r([A$t0, $2d$2d$3e$s, $.r([B$t1, $2d$2d$3e$s, number$s])]), B6347, L6348, Key6349, C6350))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(occurs$2dcheck$s, $.l((V6356, B6352, L6353, Key6354, C6355) => $.b(is$21$c.f, V6356, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6352, L6353, Key6354, C6355)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(occurs$3f$s, $.l((V6361, B6357, L6358, Key6359, C6360) => $.b(is$21$c.f, V6361, $.r([$2d$2d$3e$s, boolean$s]), B6357, L6358, Key6359, C6360)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(optimise$s, $.l((V6366, B6362, L6363, Key6364, C6365) => $.b(is$21$c.f, V6366, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6362, L6363, Key6364, C6365)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(optimise$3f$s, $.l((V6371, B6367, L6368, Key6369, C6370) => $.b(is$21$c.f, V6371, $.r([$2d$2d$3e$s, boolean$s]), B6367, L6368, Key6369, C6370)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(or$s, $.l((V6376, B6372, L6373, Key6374, C6375) => $.b(is$21$c.f, V6376, $.r([boolean$s, $2d$2d$3e$s, $.r([boolean$s, $2d$2d$3e$s, boolean$s])]), B6372, L6373, Key6374, C6375)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(os$s, $.l((V6381, B6377, L6378, Key6379, C6380) => $.b(is$21$c.f, V6381, $.r([$2d$2d$3e$s, string$s]), B6377, L6378, Key6379, C6380)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(package$3f$s, $.l((V6386, B6382, L6383, Key6384, C6385) => $.b(is$21$c.f, V6386, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6382, L6383, Key6384, C6385)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(port$s, $.l((V6391, B6387, L6388, Key6389, C6390) => $.b(is$21$c.f, V6391, $.r([$2d$2d$3e$s, string$s]), B6387, L6388, Key6389, C6390)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(porters$s, $.l((V6396, B6392, L6393, Key6394, C6395) => $.b(is$21$c.f, V6396, $.r([$2d$2d$3e$s, string$s]), B6392, L6393, Key6394, C6395)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(pos$s, $.l((V6401, B6397, L6398, Key6399, C6400) => $.b(is$21$c.f, V6401, $.r([string$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, string$s])]), B6397, L6398, Key6399, C6400)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(pr$s, $.l((V6406, B6402, L6403, Key6404, C6405) => $.b(is$21$c.f, V6406, $.r([string$s, $2d$2d$3e$s, $.r([$.r([stream$s, out$s]), $2d$2d$3e$s, string$s])]), B6402, L6403, Key6404, C6405)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(print$s, $.l(async (V6411, B6407, L6408, Key6409, C6410) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6407))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6407, (w$ = $.t(is$21$c.f(V6411, $.r([A$t0, $2d$2d$3e$s, A$t0]), B6407, L6408, Key6409, C6410))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(profile$s, $.l((V6416, B6412, L6413, Key6414, C6415) => $.b(is$21$c.f, V6416, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6412, L6413, Key6414, C6415)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(preclude$s, $.l((V6421, B6417, L6418, Key6419, C6420) => $.b(is$21$c.f, V6421, $.r([$.r([list$s, symbol$s]), $2d$2d$3e$s, $.r([list$s, symbol$s])]), B6417, L6418, Key6419, C6420)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2eproc$2dnl$s, $.l((V6426, B6422, L6423, Key6424, C6425) => $.b(is$21$c.f, V6426, $.r([string$s, $2d$2d$3e$s, string$s]), B6422, L6423, Key6424, C6425)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(profile$2dresults$s, $.l((V6431, B6427, L6428, Key6429, C6430) => $.b(is$21$c.f, V6431, $.r([symbol$s, $2d$2d$3e$s, $.r([symbol$s, $2a$s, number$s])]), B6427, L6428, Key6429, C6430)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(protect$s, $.l(async (V6436, B6432, L6433, Key6434, C6435) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6432))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6432, (w$ = $.t(is$21$c.f(V6436, $.r([A$t0, $2d$2d$3e$s, A$t0]), B6432, L6433, Key6434, C6435))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(preclude$2dall$2dbut$s, $.l((V6441, B6437, L6438, Key6439, C6440) => $.b(is$21$c.f, V6441, $.r([$.r([list$s, symbol$s]), $2d$2d$3e$s, $.r([list$s, symbol$s])]), B6437, L6438, Key6439, C6440)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2eprhush$s, $.l((V6446, B6442, L6443, Key6444, C6445) => $.b(is$21$c.f, V6446, $.r([string$s, $2d$2d$3e$s, $.r([$.r([stream$s, out$s]), $2d$2d$3e$s, string$s])]), B6442, L6443, Key6444, C6445)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(prolog$2dmemory$s, $.l((V6451, B6447, L6448, Key6449, C6450) => $.b(is$21$c.f, V6451, $.r([number$s, $2d$2d$3e$s, number$s]), B6447, L6448, Key6449, C6450)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(ps$s, $.l((V6456, B6452, L6453, Key6454, C6455) => $.b(is$21$c.f, V6456, $.r([symbol$s, $2d$2d$3e$s, $.r([list$s, unit$s])]), B6452, L6453, Key6454, C6455)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$s, $.l((V6461, B6457, L6458, Key6459, C6460) => $.b(is$21$c.f, V6461, $.r([$.r([stream$s, in$s]), $2d$2d$3e$s, unit$s]), B6457, L6458, Key6459, C6460)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$2dbyte$s, $.l((V6466, B6462, L6463, Key6464, C6465) => $.b(is$21$c.f, V6466, $.r([$.r([stream$s, in$s]), $2d$2d$3e$s, number$s]), B6462, L6463, Key6464, C6465)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$2dfile$2das$2dbytelist$s, $.l((V6471, B6467, L6468, Key6469, C6470) => $.b(is$21$c.f, V6471, $.r([string$s, $2d$2d$3e$s, $.r([list$s, number$s])]), B6467, L6468, Key6469, C6470)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$2dfile$2das$2dstring$s, $.l((V6476, B6472, L6473, Key6474, C6475) => $.b(is$21$c.f, V6476, $.r([string$s, $2d$2d$3e$s, string$s]), B6472, L6473, Key6474, C6475)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$2dfile$s, $.l((V6481, B6477, L6478, Key6479, C6480) => $.b(is$21$c.f, V6481, $.r([string$s, $2d$2d$3e$s, $.r([list$s, unit$s])]), B6477, L6478, Key6479, C6480)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$2dfrom$2dstring$s, $.l((V6486, B6482, L6483, Key6484, C6485) => $.b(is$21$c.f, V6486, $.r([string$s, $2d$2d$3e$s, $.r([list$s, unit$s])]), B6482, L6483, Key6484, C6485)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(read$2dfrom$2dstring$2dunprocessed$s, $.l((V6491, B6487, L6488, Key6489, C6490) => $.b(is$21$c.f, V6491, $.r([string$s, $2d$2d$3e$s, $.r([list$s, unit$s])]), B6487, L6488, Key6489, C6490)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(release$s, $.l((V6496, B6492, L6493, Key6494, C6495) => $.b(is$21$c.f, V6496, $.r([$2d$2d$3e$s, string$s]), B6492, L6493, Key6494, C6495)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(remove$s, $.l(async (V6501, B6497, L6498, Key6499, C6500) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6497))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6497, (w$ = $.t(is$21$c.f(V6501, $.r([A$t0, $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B6497, L6498, Key6499, C6500))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(reverse$s, $.l(async (V6506, B6502, L6503, Key6504, C6505) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6502))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6502, (w$ = $.t(is$21$c.f(V6506, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])]), B6502, L6503, Key6504, C6505))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(simple$2derror$s, $.l(async (V6511, B6507, L6508, Key6509, C6510) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6507))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6507, (w$ = $.t(is$21$c.f(V6511, $.r([string$s, $2d$2d$3e$s, A$t0]), B6507, L6508, Key6509, C6510))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(snd$s, $.l(async (V6516, B6512, L6513, Key6514, C6515) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6512))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6512, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6512))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6512, (w$ = $.t(is$21$c.f(V6516, $.r([$.r([A$t0, $2a$s, B$t1]), $2d$2d$3e$s, B$t1]), B6512, L6513, Key6514, C6515))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(specialise$s, $.l((V6521, B6517, L6518, Key6519, C6520) => $.b(is$21$c.f, V6521, $.r([symbol$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, symbol$s])]), B6517, L6518, Key6519, C6520)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(spy$s, $.l((V6526, B6522, L6523, Key6524, C6525) => $.b(is$21$c.f, V6526, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6522, L6523, Key6524, C6525)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2espy$3f$s, $.l((V6531, B6527, L6528, Key6529, C6530) => $.b(is$21$c.f, V6531, $.r([$2d$2d$3e$s, boolean$s]), B6527, L6528, Key6529, C6530)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(step$s, $.l((V6536, B6532, L6533, Key6534, C6535) => $.b(is$21$c.f, V6536, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6532, L6533, Key6534, C6535)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(shen$2estep$3f$s, $.l((V6541, B6537, L6538, Key6539, C6540) => $.b(is$21$c.f, V6541, $.r([$2d$2d$3e$s, boolean$s]), B6537, L6538, Key6539, C6540)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(stinput$s, $.l((V6546, B6542, L6543, Key6544, C6545) => $.b(is$21$c.f, V6546, $.r([$2d$2d$3e$s, $.r([stream$s, in$s])]), B6542, L6543, Key6544, C6545)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(sterror$s, $.l((V6551, B6547, L6548, Key6549, C6550) => $.b(is$21$c.f, V6551, $.r([$2d$2d$3e$s, $.r([stream$s, out$s])]), B6547, L6548, Key6549, C6550)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(stoutput$s, $.l((V6556, B6552, L6553, Key6554, C6555) => $.b(is$21$c.f, V6556, $.r([$2d$2d$3e$s, $.r([stream$s, out$s])]), B6552, L6553, Key6554, C6555)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(string$3f$s, $.l(async (V6561, B6557, L6558, Key6559, C6560) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6557))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6557, (w$ = $.t(is$21$c.f(V6561, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6557, L6558, Key6559, C6560))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(str$s, $.l(async (V6566, B6562, L6563, Key6564, C6565) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6562))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6562, (w$ = $.t(is$21$c.f(V6566, $.r([A$t0, $2d$2d$3e$s, string$s]), B6562, L6563, Key6564, C6565))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(string$2d$3en$s, $.l((V6571, B6567, L6568, Key6569, C6570) => $.b(is$21$c.f, V6571, $.r([string$s, $2d$2d$3e$s, number$s]), B6567, L6568, Key6569, C6570)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(string$2d$3esymbol$s, $.l((V6576, B6572, L6573, Key6574, C6575) => $.b(is$21$c.f, V6576, $.r([string$s, $2d$2d$3e$s, symbol$s]), B6572, L6573, Key6574, C6575)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(sum$s, $.l((V6581, B6577, L6578, Key6579, C6580) => $.b(is$21$c.f, V6581, $.r([$.r([list$s, number$s]), $2d$2d$3e$s, number$s]), B6577, L6578, Key6579, C6580)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(symbol$3f$s, $.l(async (V6586, B6582, L6583, Key6584, C6585) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6582))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6582, (w$ = $.t(is$21$c.f(V6586, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6582, L6583, Key6584, C6585))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(systemf$s, $.l((V6591, B6587, L6588, Key6589, C6590) => $.b(is$21$c.f, V6591, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6587, L6588, Key6589, C6590)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(system$2dS$3f$s, $.l((V6596, B6592, L6593, Key6594, C6595) => $.b(is$21$c.f, V6596, $.r([$2d$2d$3e$s, boolean$s]), B6592, L6593, Key6594, C6595)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tail$s, $.l(async (V6601, B6597, L6598, Key6599, C6600) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6597))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6597, (w$ = $.t(is$21$c.f(V6601, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])]), B6597, L6598, Key6599, C6600))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tlstr$s, $.l((V6606, B6602, L6603, Key6604, C6605) => $.b(is$21$c.f, V6606, $.r([string$s, $2d$2d$3e$s, string$s]), B6602, L6603, Key6604, C6605)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tlv$s, $.l(async (V6611, B6607, L6608, Key6609, C6610) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6607))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6607, (w$ = $.t(is$21$c.f(V6611, $.r([$.r([vector$s, A$t0]), $2d$2d$3e$s, $.r([vector$s, A$t0])]), B6607, L6608, Key6609, C6610))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tc$s, $.l((V6616, B6612, L6613, Key6614, C6615) => $.b(is$21$c.f, V6616, $.r([symbol$s, $2d$2d$3e$s, boolean$s]), B6612, L6613, Key6614, C6615)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tc$3f$s, $.l((V6621, B6617, L6618, Key6619, C6620) => $.b(is$21$c.f, V6621, $.r([$2d$2d$3e$s, boolean$s]), B6617, L6618, Key6619, C6620)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(thaw$s, $.l(async (V6626, B6622, L6623, Key6624, C6625) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6622))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6622, (w$ = $.t(is$21$c.f(V6626, $.r([$.r([lazy$s, A$t0]), $2d$2d$3e$s, A$t0]), B6622, L6623, Key6624, C6625))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(track$s, $.l((V6631, B6627, L6628, Key6629, C6630) => $.b(is$21$c.f, V6631, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6627, L6628, Key6629, C6630)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tracked$s, $.l((V6636, B6632, L6633, Key6634, C6635) => $.b(is$21$c.f, V6636, $.r([$2d$2d$3e$s, $.r([list$s, symbol$s])]), B6632, L6633, Key6634, C6635)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(trap$2derror$s, $.l(async (V6641, B6637, L6638, Key6639, C6640) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6637))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6637, (w$ = $.t(is$21$c.f(V6641, $.r([A$t0, $2d$2d$3e$s, $.r([$.r([exception$s, $2d$2d$3e$s, A$t0]), $2d$2d$3e$s, A$t0])]), B6637, L6638, Key6639, C6640))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(tuple$3f$s, $.l(async (V6646, B6642, L6643, Key6644, C6645) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6642))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6642, (w$ = $.t(is$21$c.f(V6646, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6642, L6643, Key6644, C6645))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(unabsolute$s, $.l((V6651, B6647, L6648, Key6649, C6650) => $.b(is$21$c.f, V6651, $.r([string$s, $2d$2d$3e$s, $.r([list$s, string$s])]), B6647, L6648, Key6649, C6650)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(undefmacro$s, $.l((V6656, B6652, L6653, Key6654, C6655) => $.b(is$21$c.f, V6656, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6652, L6653, Key6654, C6655)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(union$s, $.l(async (V6661, B6657, L6658, Key6659, C6660) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6657))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6657, (w$ = $.t(is$21$c.f(V6661, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([$.r([list$s, A$t0]), $2d$2d$3e$s, $.r([list$s, A$t0])])]), B6657, L6658, Key6659, C6660))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(unprofile$s, $.l((V6666, B6662, L6663, Key6664, C6665) => $.b(is$21$c.f, V6666, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6662, L6663, Key6664, C6665)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(untrack$s, $.l((V6671, B6667, L6668, Key6669, C6670) => $.b(is$21$c.f, V6671, $.r([symbol$s, $2d$2d$3e$s, symbol$s]), B6667, L6668, Key6669, C6670)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(userdefs$s, $.l((V6676, B6672, L6673, Key6674, C6675) => $.b(is$21$c.f, V6676, $.r([$2d$2d$3e$s, $.r([list$s, symbol$s])]), B6672, L6673, Key6674, C6675)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(variable$3f$s, $.l(async (V6681, B6677, L6678, Key6679, C6680) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6677))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6677, (w$ = $.t(is$21$c.f(V6681, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6677, L6678, Key6679, C6680))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(vector$3f$s, $.l(async (V6686, B6682, L6683, Key6684, C6685) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6682))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6682, (w$ = $.t(is$21$c.f(V6686, $.r([A$t0, $2d$2d$3e$s, boolean$s]), B6682, L6683, Key6684, C6685))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(version$s, $.l((V6691, B6687, L6688, Key6689, C6690) => $.b(is$21$c.f, V6691, $.r([$2d$2d$3e$s, string$s]), B6687, L6688, Key6689, C6690)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(write$2dto$2dfile$s, $.l(async (V6696, B6692, L6693, Key6694, C6695) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6692))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6692, (w$ = $.t(is$21$c.f(V6696, $.r([string$s, $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, A$t0])]), B6692, L6693, Key6694, C6695))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(write$2dbyte$s, $.l((V6701, B6697, L6698, Key6699, C6700) => $.b(is$21$c.f, V6701, $.r([number$s, $2d$2d$3e$s, $.r([$.r([stream$s, out$s]), $2d$2d$3e$s, number$s])]), B6697, L6698, Key6699, C6700)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f(y$2dor$2dn$3f$s, $.l((V6706, B6702, L6703, Key6704, C6705) => $.b(is$21$c.f, V6706, $.r([string$s, $2d$2d$3e$s, boolean$s]), B6702, L6703, Key6704, C6705)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3e$s, $.l((V6711, B6707, L6708, Key6709, C6710) => $.b(is$21$c.f, V6711, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, boolean$s])]), B6707, L6708, Key6709, C6710)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3c$s, $.l((V6716, B6712, L6713, Key6714, C6715) => $.b(is$21$c.f, V6716, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, boolean$s])]), B6712, L6713, Key6714, C6715)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3e$3d$s, $.l((V6721, B6717, L6718, Key6719, C6720) => $.b(is$21$c.f, V6721, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, boolean$s])]), B6717, L6718, Key6719, C6720)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3c$3d$s, $.l((V6726, B6722, L6723, Key6724, C6725) => $.b(is$21$c.f, V6726, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, boolean$s])]), B6722, L6723, Key6724, C6725)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3d$s, $.l(async (V6731, B6727, L6728, Key6729, C6730) => {
      let w$, A$t0;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6727))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6727, (w$ = $.t(is$21$c.f(V6731, $.r([A$t0, $2d$2d$3e$s, $.r([A$t0, $2d$2d$3e$s, boolean$s])]), B6727, L6728, Key6729, C6730))) instanceof Promise ? await w$ : w$));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($2b$s, $.l((V6736, B6732, L6733, Key6734, C6735) => $.b(is$21$c.f, V6736, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, number$s])]), B6732, L6733, Key6734, C6735)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($2f$s, $.l((V6741, B6737, L6738, Key6739, C6740) => $.b(is$21$c.f, V6741, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, number$s])]), B6737, L6738, Key6739, C6740)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($2d$s, $.l((V6746, B6742, L6743, Key6744, C6745) => $.b(is$21$c.f, V6746, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, number$s])]), B6742, L6743, Key6744, C6745)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), (shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($2a$s, $.l((V6751, B6747, L6748, Key6749, C6750) => $.b(is$21$c.f, V6751, $.r([number$s, $2d$2d$3e$s, $.r([number$s, $2d$2d$3e$s, number$s])]), B6747, L6748, Key6749, C6750)), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$), shen$2e$2asigf$2a$c.set((w$ = $.t(shen$2eassoc$2d$3e$c.f($3d$3d$s, $.l(async (V6756, B6752, L6753, Key6754, C6755) => {
      let w$, A$t0, B$t1;
      return (A$t0 = (w$ = $.t(shen$2enewpv$c.f(B6752))) instanceof Promise ? await w$ : w$, $.b(shen$2egc$c.f, B6752, (B$t1 = (w$ = $.t(shen$2enewpv$c.f(B6752))) instanceof Promise ? await w$ : w$, (w$ = $.t(shen$2egc$c.f(B6752, (w$ = $.t(is$21$c.f(V6756, $.r([A$t0, $2d$2d$3e$s, $.r([B$t1, $2d$2d$3e$s, boolean$s])]), B6752, L6753, Key6754, C6755))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$)));
    }), shen$2e$2asigf$2a$c.get()))) instanceof Promise ? await w$ : w$)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))));
  }));
  $.d("shen.initialise-lambda-forms", $.l(async () => {
    let w$;
    return ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([shen$2etuple$s], $.l(Y1220 => $.b(shen$2etuple$c.f, Y1220)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([shen$2epvar$s], $.l(Y1219 => $.b(shen$2epvar$c.f, Y1219)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([shen$2edictionary$s], $.l(Y1218 => $.b(shen$2edictionary$c.f, Y1218)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([and$s], $.l((Y1205, Y1206) => $.asShenBool($.asJsBool(Y1205) && $.asJsBool(Y1206))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([append$s], $.l((Y1203, Y1204) => $.b(append$c.f, Y1203, Y1204)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([arity$s], $.l(Y1202 => $.b(arity$c.f, Y1202)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([assoc$s], $.l((Y1200, Y1201) => $.b(assoc$c.f, Y1200, Y1201)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([boolean$3f$s], $.l(Y1198 => $.b(boolean$3f$c.f, Y1198)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([bound$3f$s], $.l(Y1196 => $.b(bound$3f$c.f, Y1196)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([concat$s], $.l((Y1180, Y1181) => $.b(concat$c.f, Y1180, Y1181)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([cons$s], $.l((Y1178, Y1179) => $.r([Y1178], Y1179)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([cons$3f$s], $.l(Y1177 => $.asShenBool($.isCons(Y1177))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([cn$s], $.l((Y1175, Y1176) => $.asString(Y1175) + $.asString(Y1176)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([do$s], $.l((Y1167, Y1168) => (Y1167, Y1168)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([element$3f$s], $.l((Y1165, Y1166) => $.b(element$3f$c.f, Y1165, Y1166)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([empty$3f$s], $.l(Y1164 => $.b(empty$3f$c.f, Y1164)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([explode$s], $.l(Y1158 => $.b(explode$c.f, Y1158)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([fn$s], $.l(Y1137 => $.b(fn$c.f, Y1137)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([gensym$s], $.l(Y1135 => $.b(gensym$c.f, Y1135)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([get$s], $.l((Y1132, Y1133, Y1134) => $.b(get$c.f, Y1132, Y1133, Y1134)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([$3e$s], $.l((Y1122, Y1123) => $.asShenBool($.asNumber(Y1122) > $.asNumber(Y1123))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([$3d$s], $.l((Y1118, Y1119) => $.asShenBool($.equate(Y1118, Y1119))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([hash$s], $.l((Y1116, Y1117) => $.b(hash$c.f, Y1116, Y1117)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([hd$s], $.l(Y1115 => $.asCons(Y1115).head))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([hdstr$s], $.l(Y1113 => $.b(hdstr$c.f, Y1113)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([if$s], $.l((Y1108, Y1109, Y1110) => $.asJsBool(Y1108) ? Y1109 : Y1110))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([integer$3f$s], $.l(Y1105 => $.b(integer$3f$c.f, Y1105)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([is$21$s], $.l((Y1084, Y1085, Y1086, Y1087, Y1088, Y1089) => $.b(is$21$c.f, Y1084, Y1085, Y1086, Y1087, Y1088, Y1089)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([length$s], $.l(Y1083 => $.b(length$c.f, Y1083)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([$3c$3d$s], $.l((Y1076, Y1077) => $.asShenBool($.asNumber(Y1076) <= $.asNumber(Y1077))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([vector$s], $.l(Y1075 => $.b(vector$c.f, Y1075)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([map$s], $.l((Y1072, Y1073) => $.b(map$c.f, Y1072, Y1073)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([not$s], $.l(Y1067 => $.asShenBool(!$.asJsBool(Y1067))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([prolog$2dmemory$s], $.l(Y1044 => $.b(prolog$2dmemory$c.f, Y1044)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([put$s], $.l((Y1033, Y1034, Y1035, Y1036) => $.b(put$c.f, Y1033, Y1034, Y1035, Y1036)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([reverse$s], $.l(Y1022 => $.b(reverse$c.f, Y1022)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([simple$2derror$s], $.l(Y1019 => $.raise($.asString(Y1019))))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([str$s], $.l(Y1013 => $.show(Y1013)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([symbol$3f$s], $.l(Y1005 => $.b(symbol$3f$c.f, Y1005)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([tl$s], $.l(Y1002 => $.asCons(Y1002).tail))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([thaw$s], $.l(Y1000 => $.b(thaw$c.f, Y1000)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([tlstr$s], $.l(Y999 => $.asNeString(Y999).substring(1)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([vector$s], $.l(Y975 => $.b(vector$c.f, Y975)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([vector$3f$s], $.l(Y974 => $.b(vector$3f$c.f, Y974)))))) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2eset$2dlambda$2dform$2dentry$c.f($.r([$2b$s], $.l((Y952, Y953) => $.asNumber(Y952) + $.asNumber(Y953)))))) instanceof Promise ? await w$ : w$, $.b(shen$2eset$2dlambda$2dform$2dentry$c.f, $.r([$40s$s], $.l((Y935, Y936) => $.b($40s$c.f, Y935, Y936)))))))))))))))))))))))))))))))))))))))))))))))));
  }));
  $.d("shen.initialise", $.l(async () => {
    let w$;
    return ((w$ = $.t(shen$2einitialise$2denvironment$c.f())) instanceof Promise ? await w$ : w$, ((w$ = $.t(shen$2einitialise$2dlambda$2dforms$c.f())) instanceof Promise ? await w$ : w$, $.b(shen$2einitialise$2dsignedfuncs$c.f)));
  }));
  overrides($);
  (w$ = $.t(shen$2einitialise$c.f())) instanceof Promise ? await w$ : w$;
  $.d("string-length", $.l(V1404 => "" === V1404 ? 0 : 1 + $.asNumber($.t(string$2dlength$c.f($.asNeString(V1404).substring(1))))));
  $.d("find-val", $.l((V1412, V1413) => null === V1413 ? null : $.isCons(V1413) && ($.isCons(V1413.head) && ($.isCons($.asCons(V1413.head).tail) && (null === $.asCons($.asCons(V1413.head).tail).tail && $.equate(V1412, $.asCons(V1413.head).head)))) ? $.asCons($.asCons(V1413).head).tail : $.isCons(V1413) ? $.b(find$2dval$c.f, V1412, V1413.tail) : $.raise("partial function find-val")));
  $.d("check-string", $.l(async (V1420, V1421, V1422) => {
    let w$;
    return $.isCons(V1422) && ($.isCons(V1422.head) && (s$s === $.asCons(V1422.head).head && ($.isCons($.asCons(V1422.head).tail) && (null === $.asCons($.asCons(V1422.head).tail).tail && null === V1422.tail)))) ? $.asNumber((w$ = $.t(string$2dlength$c.f($.asCons($.asCons($.asCons(V1422).head).tail).head))) instanceof Promise ? await w$ : w$) > 0 && $.asNumber((w$ = $.t(string$2dlength$c.f($.asCons($.asCons($.asCons(V1422).head).tail).head))) instanceof Promise ? await w$ : w$) <= $.asNumber(V1421) ? null : $.r([$.asString(V1420) + (": must be 1.." + ($.show(V1421) + " characters"))]) : $.isCons(V1422) && null === V1422.tail ? $.r([$.asString(V1420) + ": must be a string"]) : null === V1422 ? $.r([$.asString(V1420) + ": is required"]) : $.raise("partial function check-string");
  }));
  $.d("validate-message", $.l(async V1425 => {
    let w$;
    return $.isCons(V1425) && (obj$s === V1425.head && ($.isCons(V1425.tail) && null === $.asCons(V1425.tail).tail)) ? $.b(append$c.f, (w$ = $.t(check$2dstring$c.f("name", 40, (w$ = $.t(find$2dval$c.f("name", $.asCons($.asCons(V1425).tail).head))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$, (w$ = $.t(check$2dstring$c.f("message", 280, (w$ = $.t(find$2dval$c.f("message", $.asCons($.asCons(V1425).tail).head))) instanceof Promise ? await w$ : w$))) instanceof Promise ? await w$ : w$) : $.r(["body: must be a JSON object"]);
  }));
  $.d("valid-message?", $.l(async V1426 => {
    let w$;
    return $.b(empty$3f$c.f, (w$ = $.t(validate$2dmessage$c.f(V1426))) instanceof Promise ? await w$ : w$);
  }));
  $.d("check-fields", $.l((V1427, V1428) => $.b(validate$2dmessage$c.f, $.r([obj$s, $.r([$.r(["name", $.r([s$s, V1427])]), $.r(["message", $.r([s$s, V1428])])])]))));
  return $;
};


// A pure validator needs no real I/O; *stoutput* stays a raise-thunk (never hit).
export async function createValidator() {
  const $ = runtime({ implementation: 'ShenScript', release: 'shaken', os: 'browser', port: 'openresty-demo' });
  await run($);
  const cell = $.lookup('check-fields');
  // check-fields : string -> string -> (list string); [] means valid.
  // Shen functions may trampoline/await, so settle (and await) before reading.
  return async (name, message) => $.toArray(await $.settle(cell.f(name, message)));
}
