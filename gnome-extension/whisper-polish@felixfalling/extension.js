import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const HELPER = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'share', 'whisper-ptt', 'bin', 'whisper-ui.py']);

const WhisperIndicator = GObject.registerClass(
class WhisperIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this._dead = false;
        this._busy = false;
        this._polling = false;
        this._cancel = new Gio.Cancellable();
        this._icon = this._addIndicator();
        this._icon.iconName = 'audio-input-microphone-symbolic';
        this._icon.visible = false;
        this._all = new QuickSettings.QuickToggle({
            title: 'Whisper', subtitle: 'Checking…',
            iconName: 'system-shutdown-symbolic', toggleMode: true,
        });
        this._polish = new QuickSettings.QuickToggle({
            title: 'Cleanup', subtitle: 'Rewrite',
            iconName: 'tools-check-spelling-symbolic', toggleMode: true,
        });
        this.quickSettingsItems.push(this._all, this._polish);
        this._all.connect('clicked', () => this._change('all', this._all.checked));
        this._polish.connect('clicked', () => this._change('polish', this._polish.checked));
        this._all.reactive = false;
        this._polish.reactive = false;
        this._sync();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._sync();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _run(args, callback) {
        try {
            const proc = Gio.Subprocess.new(['python3', HELPER, ...args],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, this._cancel, (process, result) => {
                if (this._dead) return;
                try {
                    const [, stdout, stderr] = process.communicate_utf8_finish(result);
                    callback(process.get_successful() ? null : new Error(stderr.trim() || 'Command failed'), stdout);
                } catch (error) { callback(error, ''); }
            });
        } catch (error) { if (!this._dead) callback(error, ''); }
    }

    _change(kind, on) {
        if (this._busy || this._polling) return;
        this._busy = true;
        this._all.subtitle = 'Updating…';
        this._all.reactive = false;
        this._polish.reactive = false;
        this._run([kind, on ? 'on' : 'off'], error => {
            this._busy = false;
            if (error) Main.notifyError('Whisper control', error.message);
            this._sync();
        });
    }

    _sync() {
        if (this._dead || this._busy || this._polling) return;
        this._polling = true;
        // Disable clicks until this snapshot has completed, avoiding stale state races.
        this._all.reactive = false;
        this._polish.reactive = false;
        this._run(['status'], (error, output) => {
            this._polling = false;
            try {
                if (error) throw error;
                const state = JSON.parse(output);
                // Cleanup is a subordinate preference; Whisper reflects the running service.
                this._all.checked = state.active;
                this._all.subtitle = state.active ? 'On' : 'Off';
                this._polish.checked = state.polish;
                this._icon.visible = state.active;
                this._polish.subtitle = !state.active ? 'Whisper off' : (state.polish ? 'Rewrite' : 'As spoken');
                this._all.reactive = true;
                this._polish.reactive = state.active;
            } catch {
                this._all.subtitle = 'Unavailable';
            }
        });
    }

    destroy() {
        this._dead = true;
        this._cancel.cancel();
        if (this._timer) GLib.source_remove(this._timer);
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class WhisperControls extends Extension {
    enable() {
        this._indicator = new WhisperIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }
    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
