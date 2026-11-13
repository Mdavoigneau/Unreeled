import { cloudflare } from "@cloudflare/vite-plugin";
import { defineConfig } from "vite";

// The tests give each run of the relay its own storage, in RELAY_STATE, so that one test's
// phones aren't the next one's. Otherwise local storage is kept in .cloudflare/state.
const state = process.env.RELAY_STATE;

export default defineConfig({
	plugins: [cloudflare(state ? { persistState: { path: state }, inspectorPort: false } : {})],
});
