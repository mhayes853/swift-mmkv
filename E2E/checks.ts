import { createMMKV, type MMKV } from 'react-native-mmkv';

import Native, { type StoreOptions } from './modules/native-mmkv';

export type CheckResult = {
  name: string;
  passed: boolean;
  error?: string;
};

/** One store, opened by react-native-mmkv and by swift-mmkv over the same files. */
type Pair = {
  js: MMKV;
  native: StoreOptions;
};

// The app links two copies of MMKV: react-native-mmkv's and swift-mmkv's. Each keeps its own
// view of a file, so both sides open every store in multi-process mode.
function openPair(id: string, encryptionKey?: string): Pair {
  const js = createMMKV({ id, mode: 'multi-process', encryptionKey });
  js.clearAll();
  return { js, native: { id, encryptionKey } };
}

function expectEqual<T>(actual: T, expected: T, what: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`${what}: expected ${e}, got ${a}`);
  }
}

function bytes(buffer: ArrayBuffer | undefined): number[] | undefined {
  return buffer ? Array.from(new Uint8Array(buffer)) : undefined;
}

const checks: [name: string, run: () => void][] = [
  [
    'Swift reads what JavaScript wrote',
    () => {
      const { js, native } = openPair('e2e.js-to-swift');
      js.set('string', 'héllo from JavaScript 👋');
      js.set('number', 1234.5);
      js.set('boolean', true);
      js.set('buffer', new Uint8Array([0, 1, 2, 253, 254, 255]).buffer);

      expectEqual(Native.getString(native, 'string'), 'héllo from JavaScript 👋', 'string');
      expectEqual(Native.getNumber(native, 'number'), 1234.5, 'number');
      expectEqual(Native.getBoolean(native, 'boolean'), true, 'boolean');
      expectEqual(Native.getBytes(native, 'buffer'), [0, 1, 2, 253, 254, 255], 'buffer');
      expectEqual(Native.keys(native), ['boolean', 'buffer', 'number', 'string'], 'keys');
    },
  ],
  [
    'JavaScript reads what Swift wrote',
    () => {
      const { js, native } = openPair('e2e.swift-to-js');
      expectEqual(Native.setString(native, 'string', 'héllo from Swift 👋'), true, 'set string');
      expectEqual(Native.setNumber(native, 'number', -0.25), true, 'set number');
      expectEqual(Native.setBoolean(native, 'boolean', false), true, 'set boolean');
      expectEqual(Native.setBytes(native, 'buffer', [255, 0, 128]), true, 'set buffer');

      expectEqual(js.getString('string'), 'héllo from Swift 👋', 'string');
      expectEqual(js.getNumber('number'), -0.25, 'number');
      expectEqual(js.getBoolean('boolean'), false, 'boolean');
      expectEqual(bytes(js.getBuffer('buffer')), [255, 0, 128], 'buffer');
      expectEqual(js.getAllKeys().sort(), ['boolean', 'buffer', 'number', 'string'], 'keys');
    },
  ],
  [
    'Each side sees the other overwrite and remove keys',
    () => {
      const { js, native } = openPair('e2e.overwrite');
      js.set('key', 'first');
      expectEqual(Native.getString(native, 'key'), 'first', 'after the JavaScript write');
      Native.setString(native, 'key', 'second');
      expectEqual(js.getString('key'), 'second', 'after the Swift overwrite');
      js.remove('key');
      expectEqual(Native.getString(native, 'key'), null, 'after the JavaScript removal');
      Native.setString(native, 'key', 'third');
      Native.remove(native, 'key');
      expectEqual(js.contains('key'), false, 'after the Swift removal');
      Native.setString(native, 'kept', 'value');
      Native.removeAll(native);
      expectEqual(js.getAllKeys(), [], 'after Swift removed everything');
    },
  ],
  [
    'Interleaved increments from both sides lose no writes',
    () => {
      const { js, native } = openPair('e2e.increments');
      const rounds = 500;
      for (let round = 0; round < rounds; round++) {
        Native.increment(native, 'count');
        js.set('count', (js.getNumber('count') ?? 0) + 1);
      }
      expectEqual(js.getNumber('count'), rounds * 2, 'count in JavaScript');
      expectEqual(Native.getNumber(native, 'count'), rounds * 2, 'count in Swift');
    },
  ],
  [
    'Values that grow the file are seen by the other side',
    () => {
      const { js, native } = openPair('e2e.growth');
      Native.setString(native, 'small', 'x');
      const fromJS = 'j'.repeat(512 * 1024);
      js.set('large-js', fromJS);
      expectEqual(Native.getString(native, 'large-js')?.length, fromJS.length, 'JavaScript value');
      const fromSwift = 's'.repeat(2 * 1024 * 1024);
      Native.setString(native, 'large-swift', fromSwift);
      expectEqual(js.getString('large-swift')?.length, fromSwift.length, 'Swift value');
      expectEqual(js.getString('small'), 'x', 'earlier value');
    },
  ],
  [
    'An encrypted store is shared',
    () => {
      const { js, native } = openPair('e2e.encrypted', 'hunter2');
      js.set('secret', 'from JavaScript');
      expectEqual(Native.getString(native, 'secret'), 'from JavaScript', 'JavaScript value');
      Native.setNumber(native, 'pin', 4321);
      expectEqual(js.getNumber('pin'), 4321, 'Swift value');
      expectEqual(js.isEncrypted, true, 'encrypted in JavaScript');
    },
  ],
  [
    'Swift listeners hear about JavaScript writes',
    () => {
      const { js, native } = openPair('e2e.listeners');
      Native.setString(native, 'key', 'from Swift');
      expectEqual(Native.changes(native), ['key:key'], 'after the Swift write');
      js.set('key', 'from JavaScript');
      Native.checkForExternalChanges(native);
      expectEqual(Native.changes(native), ['key:key', 'external'], 'after the JavaScript write');
    },
  ],
];

export function runChecks(): CheckResult[] {
  return checks.map(([name, run]) => {
    try {
      run();
      return { name, passed: true };
    } catch (error) {
      return { name, passed: false, error: error instanceof Error ? error.message : String(error) };
    }
  });
}

/** Leaves the results where the script that launched the app can read them. */
export function reportResults(results: CheckResult[]) {
  Native.writeResults(JSON.stringify({ results }, null, 2));
}
