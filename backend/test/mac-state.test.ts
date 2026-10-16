import assert from 'node:assert/strict';
import test from 'node:test';
import {statePath} from '../src/state.js';
import {homedir} from 'node:os';
import {join} from 'node:path';
test('Mac state is isolated from XDG and supports explicit test isolation', () => {
  assert.equal(statePath({XDG_STATE_HOME:'/do-not-use'}), join(homedir(), 'Library', 'Application Support', 'SpeedChat', 'state.json'));
  assert.equal(statePath({SPEEDCHAT_STATE_DIR:'/tmp/mac-test'}), '/tmp/mac-test/state.json');
});
