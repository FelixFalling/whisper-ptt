import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch,Mock
spec=importlib.util.spec_from_file_location('controls',Path(__file__).resolve().parent.parent/'bin/whisper-ui.py')
c=importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
class Controls(unittest.TestCase):
    def test_off_stops_service_before_unload(self):
        events=[]
        with patch.object(c.sys,'argv',['ui','dictation','off']),patch.object(c.subprocess,'run',side_effect=lambda *a,**k:events.append(a[0])),patch.object(c,'unload',side_effect=lambda:events.append('unload')):
            c.main()
        self.assertEqual(events,[['systemctl','--user','stop',c.UNIT],'unload'])
    def test_stop_failure_does_not_unload(self):
        with patch.object(c.sys,'argv',['ui','dictation','off']),patch.object(c.subprocess,'run',side_effect=RuntimeError('failed')),patch.object(c,'unload') as unload:
            with self.assertRaises(RuntimeError): c.main()
            unload.assert_not_called()
    def test_cleanup_off_unloads_and_preserves_service(self):
        with TemporaryDirectory() as folder,patch.object(c,'STATE',Path(folder)/'polish'),patch.object(c.sys,'argv',['ui','polish','off']),patch.object(c.subprocess,'run') as run,patch.object(c,'unload') as unload:
            c.main()
            self.assertEqual(c.STATE.read_text(),'off\n')
            unload.assert_called_once()
            run.assert_not_called()
    def test_cleanup_on_while_stopped_does_not_warm(self):
        with TemporaryDirectory() as folder,patch.object(c,'STATE',Path(folder)/'polish'),patch.object(c.sys,'argv',['ui','polish','on']),patch.object(c,'active',return_value=False),patch.object(c.subprocess,'run') as run:
            c.main()
            self.assertEqual(c.STATE.read_text(),'on\n')
            run.assert_not_called()
    def test_master_off_stops_disables_and_unloads(self):
        events=[]
        with TemporaryDirectory() as folder,patch.object(c,'STATE',Path(folder)/'polish'),patch.object(c.sys,'argv',['ui','all','off']),patch.object(c.subprocess,'run',side_effect=lambda *a,**k:events.append(a[0])),patch.object(c,'unload',side_effect=lambda:events.append(('unload',c.STATE.read_text()))):
            c.main()
            self.assertEqual(events,[['systemctl','--user','stop',c.UNIT],('unload','off\n')])
    def test_master_on_enables_before_start_and_warms(self):
        events=[]
        with TemporaryDirectory() as folder,patch.object(c,'STATE',Path(folder)/'polish'),patch.object(c.sys,'argv',['ui','all','on']),patch.object(c.subprocess,'run',side_effect=lambda *a,**k:events.append((a[0],c.STATE.read_text()))),patch.object(c,'unload') as unload:
            c.main()
            self.assertEqual(events,[(['systemctl','--user','start',c.UNIT],'on\n'),([str(c.CLI),'polish','on','--quiet'],'on\n')])
            unload.assert_not_called()
    def test_master_off_service_failure_preserves_preference(self):
        with TemporaryDirectory() as folder,patch.object(c,'STATE',Path(folder)/'polish'),patch.object(c.sys,'argv',['ui','all','off']),patch.object(c.subprocess,'run',side_effect=RuntimeError('stop failed')),patch.object(c,'unload') as unload:
            c.STATE.write_text('on\n')
            with self.assertRaises(RuntimeError): c.main()
            self.assertEqual(c.STATE.read_text(),'on\n')
            unload.assert_not_called()
if __name__=='__main__': unittest.main()
