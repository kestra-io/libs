import { Logger } from './logging';

export interface KestraFunction {
  (): void;
  format(map: Record<string, any>): string;
  _send(map: Record<string, any>): void;
  _metrics(name: string, type: string, value: any, tags: any): void;
  assets(asset: any): void;
  outputs(outputs: any): void;
  counter(name: string, value: any, tags?: any): void;
  timer<T>(name: string, duration: number | ((callback: () => void) => T), tags?: any): T | undefined;
  gauge(name: string, value: number, tags?: any): void;
  logger(): Logger;
  context(path?: string | null): Record<string, any>;
}
