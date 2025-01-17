export interface Logger {
  trace: (...message: any) => void;
  debug: (...message: any) => void;
  info: (...message: any) => void;
  warn: (...message: any) => void;
  error: (...message: any) => void;
}

export interface Log {
  level: string;
  message: string;
}
