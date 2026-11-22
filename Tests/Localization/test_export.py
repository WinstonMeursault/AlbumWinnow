import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('export', Path(__file__).resolve().parents[2] / 'Tools/Localization/export.py')
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)

class ExportTests(unittest.TestCase):
    def sample(self):
        return {'sourceLanguage':'en', 'languages':['en','zh-Hans','ja'], 'messages':[{
            'id':'pending_count', 'context':'Cleanup candidates, not keep selection.', 'platforms':['apple','android'],
            'parameters':[{'name':'count','type':'integer'}], 'plural':'count',
            'translations':{'en':{'one':'{count} photo','other':'{count} photos'},
                            'zh-Hans':{'other':'{count} 张照片'}, 'ja':{'other':'{count}枚の写真'}}}]}
    def test_plural_export_preserves_numeric_argument_and_native_variations(self):
        catalogs=export.catalogs(self.sample())
        value=catalogs['Localizable']['strings']['pending_count']['localizations']
        self.assertEqual(value['en']['variations']['plural']['one']['stringUnit']['value'], '%1$lld photo')
        self.assertEqual(value['ja']['variations']['plural']['other']['stringUnit']['value'], '%1$lld枚の写真')
    def test_text_reordering_and_literal_percent_quotes_newlines(self):
        message={'id':'detail', 'context':'Visible detail.', 'platforms':['apple'],
                 'parameters':[{'name':'name','type':'text'},{'name':'size','type':'text'}],
                 'translations':{'en':'{name}: {size} (100%)\n"{{literal}}"', 'zh-Hans':'{size}：{name} (100%)\n"{{literal}}"', 'ja':'{name}：{size} (100%)\n"{{literal}}"'}}
        data=self.sample();data['messages']=[message]
        value=export.catalogs(data)['Localizable']['strings']['detail']['localizations']['zh-Hans']['stringUnit']['value']
        self.assertEqual(value,'%2$@：%1$@ (100%%)\n"{literal}"')
    def test_invalid_inputs_are_rejected(self):
        mutations=[
            lambda d:d['messages'].append(copy.deepcopy(d['messages'][0])),
            lambda d:d['messages'][0]['translations'].pop('ja'),
            lambda d:d['messages'][0].update(id='Not.Valid'),
            lambda d:d['messages'][0]['parameters'][0].update(type='arbitrary'),
            lambda d:d['messages'][0]['translations']['en'].update(other='{wrong} photos'),
            lambda d:d['messages'][0]['translations']['en'].pop('one'),
            lambda d:d['messages'][0]['translations']['ja'].update(other='写真'),
            lambda d:d['messages'][0].update(plural='missing'),
            lambda d:d['messages'][0]['parameters'][0].update(type='text'),
            lambda d:d['messages'][0]['translations']['en'].update(other='{count!r} photos'),
            lambda d:d['messages'][0]['translations']['en'].update(other='{count:02d} photos'),
            lambda d:d['messages'][0]['translations']['en'].update(other='{count photos'),
            lambda d:d['messages'][0].update(context=''),
            lambda d:d['messages'][0].update(platforms=['unknown']),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                data=self.sample();mutate(data)
                with self.assertRaises(ValueError):export.catalogs(data)
    def test_unknown_message_used_by_swift_is_rejected(self):
        data=self.sample()
        with self.assertRaises(ValueError):
            export.validate_usage(data, ['Text(L10n.text("pending_cout", Int64(2)))'])
        export.validate_usage(data, ['L10n.text("pending_count", Int64(2))'])
    def test_duplicate_json_members_are_not_silently_overwritten(self):
        with self.assertRaises(ValueError):export.load_json('{"a":1,"a":2}')
    def test_info_plist_is_plain_text_not_a_printf_template(self):
        data=self.sample()
        data['messages']=[{'id':'privacy_photos', 'context':'System permission purpose.', 'platforms':['apple'],
                          'table':'InfoPlist', 'appleKey':'NSPhotoLibraryUsageDescription',
                          'translations':dict.fromkeys(['en','zh-Hans','ja'],'100% local "{{photos}}"')}]
        value=export.catalogs(data)['InfoPlist']['strings']['NSPhotoLibraryUsageDescription']['localizations']['en']['stringUnit']['value']
        self.assertEqual(value,'100% local "{photos}"')

if __name__=='__main__':unittest.main()
