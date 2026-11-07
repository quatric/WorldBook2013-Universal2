// Dialog Manager alerts as NSAlerts.
#import <AppKit/AppKit.h>
#include "win.h"

const uint8_t *res_bytes(uint32_t type, int16_t id, uint32_t *len);
void ev_drop_mouseups(void);

static uint8_t params[4][256];

static void sh_ParamText(PPC *c)
{
	for (int i = 0; i < 4; i++) {
		uint32_t s = A(i);
		if (s)
			memcpy(params[i], G(s), LD8(s) + 1);
		else
			params[i][0] = 0;
	}
}

static NSString *expand(const uint8_t *s, int n)
{
	NSMutableString *out = [NSMutableString string];
	int i = 0;
	while (i < n) {
		if (s[i] == '^' && i + 1 < n && s[i + 1] >= '0' && s[i + 1] <= '3') {
			const uint8_t *p = params[s[i + 1] - '0'];
			NSString *x = mac_ns(p + 1, p[0]);
			if (x)
				[out appendString:x];
			i += 2;
			continue;
		}
		int j = i;
		while (j < n && !(s[j] == '^' && j + 1 < n && s[j + 1] >= '0' && s[j + 1] <= '3'))
			j++;
		NSString *x = mac_ns(s + i, j - i);
		if (x)
			[out appendString:x];
		i = j;
	}
	return [out stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}

static NSInteger run_alert(NSAlert *a)
{
	win_flush_all();
	NSInteger r = [a runModal];
	ev_drop_mouseups();
	return r;
}

// kind: 0 stop, 1 note, 2 caution, -1 plain
static int alert(int16_t id, int kind)
{
	uint32_t len;
	const uint8_t *alrt = res_bytes('ALRT', id, &len);
	if (!alrt || len < 12)
		return -1;
	int16_t ditl = (int16_t)(alrt[8] << 8 | alrt[9]);
	uint16_t stages = (uint16_t)(alrt[10] << 8 | alrt[11]);
	int bold = (stages & 0x8) ? 2 : 1;   // stage 1: the bold (default) button
	const uint8_t *d = res_bytes('DITL', ditl, &len);
	if (!d || len < 2)
		return -1;
	int n = (d[0] << 8 | d[1]) + 1;
	uint32_t o = 2;
	NSMutableArray *texts = [NSMutableArray array];
	int buttons[16], nb = 0;
	NSString *titles[16];
	for (int i = 1; i <= n && o + 14 <= len; i++) {
		uint8_t type = d[o + 12] & 0x7f;
		uint8_t l = d[o + 13];
		const uint8_t *data = d + o + 14;
		if (type == 4 && nb < 16) {   // button
			titles[nb] = expand(data, l);
			buttons[nb++] = i;
		} else if (type == 8 || type == 16) {   // static or edit text
			NSString *t = expand(data, l);
			if (t.length)
				[texts addObject:t];
		}
		o += 14 + l + (l & 1);
	}
	NSAlert *a = [NSAlert new];
	a.alertStyle = kind == 0 ? NSAlertStyleCritical : kind == 2 ? NSAlertStyleWarning : NSAlertStyleInformational;
	if (texts.count) {
		a.messageText = texts[0];
		if (texts.count > 1)
			a.informativeText = [[texts subarrayWithRange:NSMakeRange(1, texts.count - 1)] componentsJoinedByString:@"\n\n"];
	} else
		a.messageText = @"";
	// the default button first
	int order[16], no = 0;
	for (int i = 0; i < nb; i++)
		if (buttons[i] == bold)
			order[no++] = i;
	for (int i = 0; i < nb; i++)
		if (buttons[i] != bold)
			order[no++] = i;
	for (int i = 0; i < no; i++) {
		NSButton *b = [a addButtonWithTitle:titles[order[i]]];
		NSString *t = titles[order[i]];
		if (i > 0 && ([t isEqualToString:@"Cancel"] || [t isEqualToString:@"No"]))
			b.keyEquivalent = @"\033";
	}
	if (!no)
		[a addButtonWithTitle:@"OK"];
	NSInteger r = run_alert(a) - NSAlertFirstButtonReturn;
	if (!no)
		return 1;
	return r >= 0 && r < no ? buttons[order[r]] : 1;
}

static void sh_Alert(PPC *c) { RET(alert((int16_t)A(0), -1)); }
static void sh_StopAlert(PPC *c) { RET(alert((int16_t)A(0), 0)); }
static void sh_NoteAlert(PPC *c) { RET(alert((int16_t)A(0), 1)); }
static void sh_CautionAlert(PPC *c) { RET(alert((int16_t)A(0), 2)); }

static NSString *pstr_or(uint32_t s, NSString *dflt)
{
	if (s == 0xffffffffu)
		return dflt;
	if (!s)
		return nil;
	return pstr_ns(s);
}

static void sh_StandardAlert(PPC *c)
{
	// StandardAlert(alertType, error, explanation, const AlertStdAlertParamRec *, SInt16 *itemHit)
	int type = (int16_t)A(0);
	NSAlert *a = [NSAlert new];
	a.alertStyle = type == 0 ? NSAlertStyleCritical : type == 2 ? NSAlertStyleWarning : NSAlertStyleInformational;
	a.messageText = A(1) ? [pstr_ns(A(1)) stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"] : @"";
	if (A(2) && LD8(A(2)))
		a.informativeText = [pstr_ns(A(2)) stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
	uint32_t p = A(3);
	NSString *def = @"OK", *cancel = nil, *other = nil;
	int defItem = 1;
	if (p) {
		def = pstr_or(LD32(p + 6), @"OK");
		cancel = pstr_or(LD32(p + 10), @"Cancel");
		other = pstr_or(LD32(p + 14), @"Don't Save");
		defItem = (int16_t)LD16(p + 18);
	}
	int items[3], ni = 0;
	NSString *titles[3];
	// the default button first, then cancel, then other
	NSString *byItem[4] = {nil, def, cancel, other};
	if (defItem >= 1 && defItem <= 3 && byItem[defItem]) {
		titles[ni] = byItem[defItem];
		items[ni++] = defItem;
	}
	for (int k = 1; k <= 3; k++)
		if (k != defItem && byItem[k]) {
			titles[ni] = byItem[k];
			items[ni++] = k;
		}
	for (int i = 0; i < ni; i++) {
		NSButton *b = [a addButtonWithTitle:titles[i]];
		if (items[i] == 2 && i > 0)
			b.keyEquivalent = @"\033";
	}
	if (!ni) {
		[a addButtonWithTitle:@"OK"];
		items[ni++] = 1;
	}
	NSInteger r = run_alert(a) - NSAlertFirstButtonReturn;
	if (A(4))
		ST16(A(4), (uint16_t)(r >= 0 && r < ni ? items[r] : 1));
	RET(0);
}

static void sh_GetDialogItem(PPC *c)
{
	// GetDialogItem(dialog, item, &type, &handle, &box): no Dialog Manager dialogs exist
	if (A(2))
		ST16(A(2), 0);
	if (A(3))
		ST32(A(3), 0);
	if (A(4))
		PUTRECT(A(4), (QRect){0, 0, 0, 0});
}
static void sh_StdFilterProc(PPC *c) { (void)c; RET(0); }
static void sh_SetDialogDefaultItem(PPC *c) { (void)c; RET(0); }
static void sh_SetDialogCancelItem(PPC *c) { (void)c; RET(0); }

static const ShimDef dlgshims[] = {
	S(ParamText), S(Alert), S(StopAlert), S(NoteAlert), S(CautionAlert), S(StandardAlert), S(GetDialogItem),
	S(StdFilterProc), S(SetDialogDefaultItem), S(SetDialogCancelItem),
};
REGISTER(dlgshims)
