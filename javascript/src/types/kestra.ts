import { Logger } from './logging';

export interface KestraFunction {
  (): void;
  format(map: Record<string, any>): string;
  _send(map: Record<string, any>): void;
  _metrics(name: string, type: string, value: any, tags: any): void;
  outputs(outputs: any): void;
  counter(name: string, value: any, tags: any): void;
  timer(name: string, duration: number | ((callback: () => void) => void), tags: any): void;
  gauge(name: string, value: number, tags: any): void;
  logger(): Logger;
}
