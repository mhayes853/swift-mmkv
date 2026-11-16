import { requireNativeModule } from 'expo';

export type StoreOptions = {
  id?: string;
  encryptionKey?: string;
};

/** swift-mmkv, as the native side of the app sees it. */
export type NativeMMKV = {
  rootDirectory(): string;
  setString(store: StoreOptions, key: string, value: string): boolean;
  getString(store: StoreOptions, key: string): string | null;
  setNumber(store: StoreOptions, key: string, value: number): boolean;
  getNumber(store: StoreOptions, key: string): number | null;
  setBoolean(store: StoreOptions, key: string, value: boolean): boolean;
  getBoolean(store: StoreOptions, key: string): boolean | null;
  setBytes(store: StoreOptions, key: string, value: number[]): boolean;
  getBytes(store: StoreOptions, key: string): number[] | null;
  keys(store: StoreOptions): string[];
  remove(store: StoreOptions, key: string): boolean;
  removeAll(store: StoreOptions): void;
  increment(store: StoreOptions, key: string): number;
  checkForExternalChanges(store: StoreOptions): void;
  changes(store: StoreOptions): string[];
  writeResults(json: string): void;
};

export default requireNativeModule<NativeMMKV>('NativeMMKV');
