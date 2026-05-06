import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

test("viewer video surface disables native media affordances", async () => {
  const html = await readFile(
    fileURLToPath(new URL("../viewer/index.html", import.meta.url)),
    "utf8",
  );
  const source = await readFile(
    fileURLToPath(new URL("../viewer/viewer.js", import.meta.url)),
    "utf8",
  );

  assert.match(html, /<video[\s\S]*id="remoteVideo"[\s\S]*disablepictureinpicture/);
  assert.match(html, /<video[\s\S]*id="remoteVideo"[\s\S]*disableremoteplayback/);
  assert.match(html, /<video[\s\S]*id="remoteVideo"[\s\S]*controlslist="nodownload nofullscreen noremoteplayback"/);
  assert.doesNotMatch(html, /<video[\s\S]*id="remoteVideo"[\s\S]*\scontrols(?:\s|>|=)/);

  assert.match(source, /remoteVideo\.disablePictureInPicture = true/);
  assert.match(source, /remoteVideo\.disableRemotePlayback = true/);
  assert.match(source, /remoteVideo\.removeAttribute\("controls"\)/);
  assert.match(source, /remoteVideo\.addEventListener\("contextmenu"/);
  assert.match(source, /remoteVideo\.addEventListener\("dblclick"/);
  assert.match(source, /remoteVideo\.addEventListener\("enterpictureinpicture"/);
  assert.match(source, /document\.addEventListener\("fullscreenchange"/);
});
