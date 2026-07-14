/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_RPC_URL?: string;
  readonly VITE_HOOK_ADDRESS?: string;
  readonly VITE_MIRROR_ADDRESS?: string;
}
interface ImportMeta {
  readonly env: ImportMetaEnv;
}
