declare module 'bucket/*' {
  export const mount: import('./remote').RemoteModule['mount'];
}
