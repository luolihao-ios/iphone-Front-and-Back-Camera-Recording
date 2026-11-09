import unittest

from tools import release_1_0_15_screenshots as release


def placement(image_id, group=release.GROUP):
    return {
        'id': 'placement-' + image_id,
        'attributes': {'placementType': 'APP_SCREENSHOT', 'placementGroup': group},
        'relationships': {'image': {'data': {'id': image_id}}},
    }


def baseline():
    return {
        'en-US': [placement(str(i)) for i in range(1, 7)] + [placement('ipad-en', 'IPAD_13_PROFILE')],
        'zh-Hans': [placement('original-zh')],
        'zh-Hant': [placement('original-tw')],
    }


class ScopedScreenshotReleaseTests(unittest.TestCase):
    def test_keeps_last_three_and_moves_only_replaced_associations_to_end(self):
        before = baseline()
        after = baseline()
        after['en-US'] += [placement(s) for s in ('vlog', 'reaction', 'interview')]
        order, obsolete = release.replacement_order(before, after, ['vlog', 'reaction', 'interview'])
        self.assertEqual(order, ['placement-vlog', 'placement-reaction', 'placement-interview',
                                 'placement-4', 'placement-5', 'placement-6',
                                 'placement-1', 'placement-2', 'placement-3'])
        self.assertEqual(obsolete, ['placement-1', 'placement-2', 'placement-3'])

    def test_rejects_change_to_any_untargeted_group(self):
        after = baseline()
        after['zh-Hant'] = [placement('wrong-translation')]
        with self.assertRaisesRegex(ValueError, '其他语言或设备'):
            release.replacement_order(baseline(), after, ['vlog', 'reaction', 'interview'])

    def test_refuses_to_delete_a_new_unknown_asset(self):
        after = baseline()
        after['en-US'].append(placement('somebody-elses-image'))
        with self.assertRaisesRegex(ValueError, '未知素材'):
            release.replacement_order(baseline(), after, ['vlog', 'reaction', 'interview'])

    def test_readback_retains_last_three_in_order(self):
        after = baseline()
        after['en-US'][:3] = [placement(s) for s in ('vlog', 'reaction', 'interview')]
        release.verify_final(baseline(), after, ['vlog', 'reaction', 'interview'])
        after['en-US'][4], after['en-US'][5] = after['en-US'][5], after['en-US'][4]
        with self.assertRaisesRegex(ValueError, '数量或顺序'):
            release.verify_final(baseline(), after, ['vlog', 'reaction', 'interview'])
