/**
 * Direct gRPC client for `apiextensions.fn.proto.v1.FunctionRunnerService`.
 *
 * The benchmark talks to the functions itself rather than through
 * `crossplane render`: the CLI would add YAML parsing, process spawning and its
 * own composition merge to every sample, which is exactly the noise we want out
 * of the numbers.
 */
import { credentials, loadPackageDefinition, Client } from '@grpc/grpc-js';
import type { ServiceError } from '@grpc/grpc-js';
import { loadSync } from '@grpc/proto-loader';
import type { Struct } from './struct.ts';

export interface Resource {
  resource?: Struct;
  ready?: string;
  connectionDetails?: Record<string, Buffer>;
}

export interface State {
  composite?: Resource;
  resources?: Record<string, Resource>;
}

export interface Result {
  severity?: string;
  message?: string;
  reason?: string;
  target?: string;
}

export interface RunFunctionRequest {
  meta?: { tag: string };
  observed?: State;
  desired?: State;
  input?: Struct;
  context?: Struct;
}

export interface RunFunctionResponse {
  meta?: { tag?: string };
  desired?: State;
  results?: Result[];
  context?: Struct;
  conditions?: { type?: string; status?: string; reason?: string; message?: string }[];
}

type RunFunction = (
  req: RunFunctionRequest,
  opts: { deadline: number },
  cb: (err: ServiceError | null, res?: RunFunctionResponse) => void
) => void;

export interface FunctionClient extends Client {
  RunFunction: RunFunction;
}

/**
 * Connect to a function. `google/protobuf/{struct,duration}.proto` resolve out
 * of protobufjs' bundled well-known types, so no include path is needed.
 */
export function connectFunction(protoPath: string, address: string): FunctionClient {
  const definition = loadSync(protoPath, {
    keepCase: false,
    longs: String,
    enums: String,
    defaults: false,
    oneofs: true,
  });
  const pkg = loadPackageDefinition(definition) as unknown as {
    apiextensions: {
      fn: { proto: { v1: { FunctionRunnerService: new (...args: unknown[]) => FunctionClient } } };
    };
  };
  const Service = pkg.apiextensions.fn.proto.v1.FunctionRunnerService;
  return new Service(address, credentials.createInsecure(), {
    'grpc.max_receive_message_length': 64 * 1024 * 1024,
    'grpc.max_send_message_length': 64 * 1024 * 1024,
  });
}

/**
 * Block until the function answers gRPC. Necessary because docker publishes the
 * container port before the server behind it listens, so a bare TCP connect is
 * not a readiness signal — `waitForReady` retries the handshake instead.
 */
export function waitForReady(client: FunctionClient, timeoutMs = 120_000): Promise<void> {
  const { promise, resolve, reject } = Promise.withResolvers<void>();
  client.waitForReady(Date.now() + timeoutMs, (err) => (err ? reject(err) : resolve()));
  return promise;
}

export interface Sample {
  response: RunFunctionResponse;
  /** Wall time of the unary call, nanoseconds. */
  elapsedNs: bigint;
}

export async function runFunction(
  client: FunctionClient,
  req: RunFunctionRequest,
  timeoutMs = 120_000
): Promise<Sample> {
  const { promise, resolve, reject } = Promise.withResolvers<Sample>();
  const startedAt = process.hrtime.bigint();
  client.RunFunction(req, { deadline: Date.now() + timeoutMs }, (err, response) => {
    const elapsedNs = process.hrtime.bigint() - startedAt;
    if (err || !response) {
      reject(err ?? new Error('RunFunction returned no response'));
      return;
    }
    resolve({ response, elapsedNs });
  });
  return promise;
}
