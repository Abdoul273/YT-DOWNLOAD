import unittest

from app import build_format_selection


class FormatSelectionTests(unittest.TestCase):
    def test_falls_back_to_bestvideo_and_bestaudio(self):
        fmt_sel, merge_fmt = build_format_selection('720', 'mp4', '', '', True)
        self.assertEqual(fmt_sel, 'bestvideo[height<=720]+bestaudio/best')
        self.assertEqual(merge_fmt, 'mp4')

    def test_prefers_explicit_audio_format_id(self):
        fmt_sel, merge_fmt = build_format_selection('1080', 'mkv', '140', '', True)
        self.assertIn('140', fmt_sel)
        self.assertEqual(merge_fmt, 'mkv')

    def test_uses_audio_language_when_available(self):
        fmt_sel, merge_fmt = build_format_selection('best', 'webm', '', 'fr', True)
        self.assertIn('language=fr', fmt_sel)
        self.assertEqual(merge_fmt, 'webm')


if __name__ == '__main__':
    unittest.main()
