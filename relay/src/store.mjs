// Tiny JSON-file store. Holds the relay's single Mozilla identity (uaid) and one record per device:
//   { deviceId, channelID, endpoint, apnsToken, sandbox, topic, createdAt }
// It deliberately stores NO ECDH keys and NO plaintext — the phone owns those, so a compromise of
// this file leaks only transport identifiers, never message content. Swap for SQLite (node:sqlite)
// if you outgrow a JSON file; the interface below is all the rest of the service depends on.
import fs from "node:fs";
import path from "node:path";

export class Store {
  constructor(file) {
    this.file = file;
    this.data = { uaid: null, devices: {} }; // devices keyed by channelID
    this._load();
  }

  _load() {
    try { this.data = JSON.parse(fs.readFileSync(this.file, "utf8")); } catch { /* fresh */ }
    this.data.devices ||= {};
  }

  _save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.file); // atomic replace
  }

  getUaid() { return this.data.uaid; }
  setUaid(uaid) { this.data.uaid = uaid; this._save(); }

  channelIDs() { return Object.keys(this.data.devices); }
  devices() { return Object.values(this.data.devices); }
  getByChannel(channelID) { return this.data.devices[channelID]; }
  getByDeviceId(deviceId) { return this.devices().find((d) => d.deviceId === deviceId); }

  addDevice(device) { this.data.devices[device.channelID] = device; this._save(); }
  removeByChannel(channelID) { delete this.data.devices[channelID]; this._save(); }

  /** Changes fields of a device's record, such as its APNs token. */
  updateDevice(channelID, fields) {
    const device = this.data.devices[channelID];
    if (!device) return;
    Object.assign(device, fields);
    this._save();
  }

  /** Moves a device to a new channel and endpoint, after Mozilla dropped the old ones. */
  moveDevice(oldChannelID, channelID, endpoint) {
    const device = this.data.devices[oldChannelID];
    if (!device) return;
    delete this.data.devices[oldChannelID];
    this.data.devices[channelID] = { ...device, channelID, endpoint };
    this._save();
  }
}
