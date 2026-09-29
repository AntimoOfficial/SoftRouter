#!/usr/bin/python3
"""Desktop controller for the experimental NetworkManager edition."""
import json
from pathlib import Path
import subprocess
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

INSTALL = Path('/opt/softrouter')
BACKEND = INSTALL / 'backend.py'


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('SoftRouter — Linux community test')
        self.geometry('960x720')
        self.minsize(720, 520)
        self.config_data = None
        self.busy = False
        frame = ttk.Frame(self, padding=18)
        frame.pack(fill='both', expand=True)
        ttk.Label(frame, text='SoftRouter for Linux', font=('Sans', 22, 'bold')).pack(anchor='w')
        ttk.Label(frame, text='Experimental NetworkManager adapter • No real Linux network acceptance yet',
                  wraplength=850).pack(anchor='w', pady=(4, 12))
        ttk.Label(frame, text='Use a connected upstream and a separate, idle Ethernet downstream. '
                  'Sharing uses the current default route and is not pinned to your selected upstream. '
                  'NetworkManager owns DHCP, DNS and NAT; closing this window does not stop sharing.',
                  wraplength=850).pack(anchor='w')
        self.config_label = ttk.Label(frame, text='No configuration imported. Inspect adapters before choosing a configuration.')
        self.config_label.pack(anchor='w', pady=12)
        row = ttk.Frame(frame)
        row.pack(fill='x')
        self.buttons = []
        for label, action in [('Inspect adapters / status', self.inspect), ('Import JSON config', self.import_config),
                              ('Enable sharing…', self.enable), ('Disable owned sharing…', self.disable)]:
            button = ttk.Button(row, text=label, command=action)
            button.pack(side='left', padx=(0, 8))
            self.buttons.append(button)
        self.status = ttk.Label(frame, text='Ready. Inspection is read-only. Network changes require explicit administrator approval.')
        self.status.pack(anchor='w', pady=12)
        content = ttk.Frame(frame)
        content.pack(fill='both', expand=True)
        self.output = tk.Text(content, wrap='word', state='disabled', font=('Monospace', 10))
        scrollbar = ttk.Scrollbar(content, orient='vertical', command=self.output.yview)
        self.output.configure(yscrollcommand=scrollbar.set)
        self.output.pack(side='left', fill='both', expand=True)
        scrollbar.pack(side='right', fill='y')
        ttk.Label(frame, text='No power, sleep or Wi-Fi settings are changed. Profile activity does not prove downstream internet access.',
                  wraplength=850).pack(anchor='w', pady=(12, 0))

    def show(self, text):
        self.output.configure(state='normal')
        self.output.delete('1.0', 'end')
        self.output.insert('end', text)
        self.output.configure(state='disabled')

    def import_config(self):
        chosen = filedialog.askopenfilename(title='Import local SoftRouter configuration', filetypes=[('JSON data', '*.json')])
        if not chosen:
            return
        try:
            source = Path(chosen)
            if source.stat().st_size > 8192:
                raise ValueError('Configuration is larger than 8192 bytes.')
            # Validate data with the same installed backend module; never execute config content.
            import backend
            self.config_data = backend.validate_config(backend.decode(source.read_text(encoding='utf-8')))
        except (OSError, ValueError, RuntimeError) as exc:
            messagebox.showerror('Configuration rejected', str(exc))
            return
        self.config_label.configure(text='Imported: ' + self.config_data['upstream_interface'] + ' → '
                                    + self.config_data['downstream_interface'] + ' • ' + self.config_data['downstream_address'])
        self.show(json.dumps(self.config_data, indent=2))

    def call(self, action, privileged=False):
        if self.busy:
            return
        if not BACKEND.is_file():
            messagebox.showerror('App installation required', 'Run the app-only installer first. Expected /opt/softrouter/backend.py.')
            return
        command = ['/usr/bin/python3', '-I', str(BACKEND), action]
        if privileged:
            command.insert(0, '/usr/bin/pkexec')
        data = json.dumps(self.config_data) if self.config_data and action in ('enable', 'inspect') else ''
        self.busy = True
        for button in self.buttons:
            button.configure(state='disabled')
        self.status.configure(text='Waiting for administrator approval…' if privileged else 'Reading NetworkManager state…')

        def work():
            try:
                result = subprocess.run(command, input=data, capture_output=True, text=True, timeout=300, check=False)
                text = result.stdout.strip() or result.stderr.strip() or 'No diagnostic output was returned.'
                ok = result.returncode == 0
            except (OSError, subprocess.TimeoutExpired) as exc:
                text = str(exc) + '\nIf an operation was interrupted, inspect and disable owned sharing before retrying.'
                ok = False
            self.after(0, lambda: self.finish(text, ok))
        threading.Thread(target=work, daemon=True).start()

    def finish(self, text, ok):
        self.busy = False
        for button in self.buttons:
            button.configure(state='normal')
        summary = 'Operation finished. Read the evidence and limitations below.' if ok else 'Attention required. No successful network outcome is assumed.'
        if ok:
            try:
                state = json.loads(text).get('status')
                summary = {'configured': 'Configured — waiting for an Ethernet cable. Sharing is not yet verified active.',
                           'active': 'NetworkManager profile active — real downstream access is still unverified.',
                           'disabled': 'Owned sharing profile removed. Full system restoration was not measured.'}.get(state, summary)
            except (ValueError, AttributeError):
                pass
        self.status.configure(text=summary)
        self.show(text)

    def inspect(self):
        self.call('inspect')

    def enable(self):
        if not self.config_data:
            messagebox.showerror('Configuration required', 'Inspect the adapters and import a configuration with their actual identities first.')
            return
        plan = ('Enable a persistent NetworkManager shared profile on ' + self.config_data['downstream_interface']
                + ' at ' + self.config_data['downstream_address'] + '?\n\n'
                'The selected upstream must be the current default: ' + self.config_data['upstream_interface']
                + '. NAT will follow later default-route changes. DHCP and DNS will be provided to downstream. '
                'This profile is configured to reconnect after reboot; recovery and downstream access remain unverified. '
                'Existing sharing or a non-idle downstream will be refused.\n\nAdministrator approval follows.')
        if messagebox.askyesno('Enable sharing', plan, default='no'):
            self.call('enable', privileged=True)

    def disable(self):
        if messagebox.askyesno('Disable owned sharing', 'Deactivate and remove only the unchanged NetworkManager UUID recorded by SoftRouter? '
                              'Downstream clients will lose this shared connection. Unknown or edited profiles are preserved.\n\nAdministrator approval follows.', default='no'):
            self.call('disable', privileged=True)


if __name__ == '__main__':
    App().mainloop()
