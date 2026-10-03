/**
 * Structured one-line JSON logs. Callers pass counts, ids and statuses only:
 * never an e-mail address, a code, a token, a request body or a response body.
 */
export type LogFields = Record<string, string | number | boolean | null | undefined>;

export interface Logger {
  info(fields: LogFields, msg?: string): void;
  warn(fields: LogFields, msg?: string): void;
  error(fields: LogFields, msg?: string): void;
}

type Level = "info" | "warn" | "error";

export function createLogger(
  write: (level: Level, line: string) => void = defaultWrite,
  now: () => Date = () => new Date(),
): Logger {
  const emit = (level: Level) => (fields: LogFields, msg?: string) => {
    const line: Record<string, unknown> = { time: now().toISOString(), level, ...fields };
    if (msg !== undefined) line.msg = msg;
    write(level, JSON.stringify(line));
  };
  return { info: emit("info"), warn: emit("warn"), error: emit("error") };
}

function defaultWrite(level: Level, line: string): void {
  (level === "info" ? process.stdout : process.stderr).write(line + "\n");
}
