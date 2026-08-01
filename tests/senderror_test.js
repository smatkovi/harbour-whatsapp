const fs = require('fs');
const qml = fs.readFileSync(__dirname + '/../qml/harbour-whatsapp.qml', 'utf8');
const trSrc = fs.readFileSync(__dirname + '/../qml/translations.js', 'utf8').split('\n').slice(1).join('\n');
const TR = (new Function(trSrc + '; return {catalog: catalog};'))();

// Die echten Funktionen aus der ausgelieferten QML-Datei schneiden
function grab(name) {
  const i = qml.indexOf('    function ' + name + '(');
  if (i < 0) throw new Error('nicht gefunden: ' + name);
  let depth = 0, started = false, j = i;
  for (; j < qml.length; j++) {
    if (qml[j] === '{') { depth++; started = true; }
    else if (qml[j] === '}') { depth--; if (started && depth === 0) { j++; break; } }
  }
  return qml.slice(i, j);
}
const src = grab('sendRejectCode') + '\n' + grab('sendErrorText');

function ctx(lang, configured, effective, daemon, missing) {
  const loc = TR.catalog(lang);
  return (new Function('loc', 'mediaPermConfigured', 'mediaPermEffective', 'daemonRunning', 'mediaPermMissing',
    src + '; return {sendRejectCode: sendRejectCode, sendErrorText: sendErrorText};'))(
      loc, configured === true, effective === true, daemon === true, missing || "");
}

let fails = 0;
function check(name, got, pred, expl) {
  const ok = pred(got);
  if (!ok) { fails++; console.log('  FEHLGESCHLAGEN  ' + name + '\n      bekam: ' + JSON.stringify(got) + '\n      ' + expl); }
  else console.log('  ok  ' + name);
}

const de = ctx('de'), en = ctx('en');

console.log('--- sendRejectCode: welche Antworten gelten als Ablehnung? ---');
check('463 (der reale Fall)',        de.sendRejectCode('server returned error 463'), v => v === 463, 'erwartet 463');
check('400 untere Grenze',           de.sendRejectCode('server returned error 400'), v => v === 400, 'erwartet 400');
check('499 obere Grenze',            de.sendRejectCode('server returned error 499'), v => v === 499, 'erwartet 499');
check('500 ist KEINE Ablehnung',     de.sendRejectCode('server returned error 500'), v => v === 0,   'erwartet 0');
check('399 ist KEINE Ablehnung',     de.sendRejectCode('server returned error 399'), v => v === 0,   'erwartet 0');
check('anderer Fehlertext',          de.sendRejectCode('no LID found for 4366 from server'), v => v === 0, 'erwartet 0');
check('leerer Text',                 de.sendRejectCode(''), v => v === 0, 'erwartet 0');
check('undefined',                   de.sendRejectCode(undefined), v => v === 0, 'erwartet 0');
check('Ziffern anderswo im Text',    de.sendRejectCode('upload failed after 463 seconds'), v => v === 0, 'erwartet 0');

console.log('--- sendErrorText: was liest der Nutzer? ---');
const t463 = de.sendErrorText(500, 'server returned error 463');
check('463 -> Klartext statt Code',  t463, v => v.indexOf('463') >= 0 && v.indexOf('WhatsApp') >= 0 && v.indexOf('server returned') < 0,
      'erwartet uebersetzte Erklaerung mit Codenummer, ohne Rohtext');
check('463 -> Warnung vor Wiederholung', t463, v => v.indexOf('nicht wiederholen') >= 0, 'erwartet Hinweis');
check('463 englisch',                en.sendErrorText(500, 'server returned error 463'),
      v => v.indexOf('do not retry') >= 0 && v.indexOf('463') >= 0, 'erwartet englische Fassung');
check('kein Backend',                de.sendErrorText(0, ''), v => v.indexOf('keine Antwort vom Backend') >= 0, 'erwartet Backend-Hinweis');
check('Status im Text',              de.sendErrorText(503, 'service unavailable'), v => v.indexOf('503') >= 0, 'erwartet Statusnummer');
check('Rohtext durchgereicht',       de.sendErrorText(500, 'no LID found for 4366'), v => v.indexOf('no LID found') >= 0, 'erwartet Originalfehler');
const perm = de.sendErrorText(500, 'open /run/media/defaultuser/D1E4-D00D/TWRP/BACKUPS/x/fsg.emmc.win.sha2: permission denied');
check('Sandbox-Fehler erkannt',      perm, v => v.indexOf('Sailjail') >= 0 && v.indexOf('SD-Karte') >= 0, 'erwartet Hinweis auf die Speicher-Berechtigung');
check('Pfad bleibt sichtbar',        perm, v => v.indexOf('fsg.emmc.win.sha2') >= 0, 'erwartet den Dateipfad zur Einordnung');
check('Sandbox-Fehler englisch',     en.sendErrorText(500, 'open /x: permission denied'), v => v.indexOf('sandbox') >= 0, 'erwartet englische Fassung');
const withDaemon = ctx('de', true, false, true);
check('nicht wirksam, Daemon laeuft', withDaemon.sendErrorText(500, 'open /x: permission denied'),
      v => v.indexOf('Hintergrunddienst') >= 0 && v.indexOf('Kachel') < 0,
      'erwartet Dienst-Neustart, nicht App schliessen');
const noDaemon = ctx('de', true, false, false);
check('nicht wirksam, kein Daemon',  noDaemon.sendErrorText(500, 'open /x: permission denied'),
      v => v.indexOf('vollst') >= 0 && v.indexOf('Hintergrunddienst') < 0,
      'erwartet App-Neustart, kein Hinweis auf einen Dienst den es nicht gibt');
check('kein Daemon, englisch',       ctx('en', true, false, false).sendErrorText(500, 'open /x: permission denied'),
      v => v.indexOf('Close the app') >= 0, 'erwartet englische App-Fassung');
const partial = ctx('de', false, false, true, 'RemovableMedia');
check('Teil-Grant benennt das Fehlende', partial.sendErrorText(500, 'open /run/media/x: permission denied'),
      v => v.indexOf('RemovableMedia') >= 0 && v.indexOf('SD-Karte') >= 0 && v.indexOf('erneut') >= 0,
      'erwartet Name der fehlenden Marke und Hinweis auf erneuten Lauf');
const partial2 = ctx('de', false, false, true, 'MediaIndexing, RemovableMedia');
check('zwei fehlende Marken',        partial2.sendErrorText(500, 'open /x: permission denied'),
      v => v.indexOf('MediaIndexing, RemovableMedia') >= 0, 'erwartet beide Namen');
const nothing = ctx('de', false, false, true, 'UserDirs, MediaIndexing, RemovableMedia');
check('gar nichts erteilt',          nothing.sendErrorText(500, 'open /x: permission denied'),
      v => v.indexOf('nur teilweise') < 0, 'bei komplett fehlender Berechtigung kein Teil-Grant-Text');
const active = ctx('de', true, true, true, '');
check('erteilt und wirksam',         active.sendErrorText(500, 'open /x: permission denied'),
      v => v.indexOf('Sailjail') >= 0 && v.indexOf('noch nicht wirksam') < 0,
      'bei wirksamer Berechtigung kein Neustart-Hinweis');
check('463 bleibt Ablehnung',        de.sendErrorText(500, 'server returned error 463'), v => v.indexOf('Sailjail') < 0, 'Server-Ablehnung darf nicht als Sandbox-Fehler gelten');
const long = de.sendErrorText(500, 'x'.repeat(500));
check('langer Text gekuerzt',        long, v => v.length < 260 && v.indexOf('\u2026') >= 0, 'erwartet Kuerzung mit Auslassung');
check('Zeilenumbrueche im Body',     de.sendErrorText(500, 'zeile1\nzeile2\n\n'), v => v.indexOf('zeile2') >= 0, 'erwartet beide Zeilen, ohne Leerlauf am Ende');

console.log('--- alle 23 Kataloge: Platzhalter und Vollstaendigkeit ---');
const langs = ['en','de','fi','sv','hu','ru','fr','la','es','it','pt','nl','pl','tr','da','nb','cs','el','et','lv','lt','sl','zh'];
let bad = [];
for (const l of langs) {
  const c = ctx(l), txt = c.sendErrorText(500, 'server returned error 463'), gen = c.sendErrorText(502, 'boom');
  if (txt.indexOf('463') < 0) bad.push(l + ' (Code fehlt in sendRejected)');
  if (txt.indexOf('%1') >= 0) bad.push(l + ' (Platzhalter nicht ersetzt)');
  if (gen.indexOf('502') < 0) bad.push(l + ' (Status fehlt in sendFailed)');
  if (gen.indexOf('%1') >= 0) bad.push(l + ' (Platzhalter in sendFailed)');
  if (c.sendErrorText(500, 'open /x: permission denied').indexOf('%1') >= 0) bad.push(l + ' (Platzhalter in sendPermissionDenied)');
}
check('Platzhalter in allen Sprachen', bad, v => v.length === 0, 'Probleme: ' + bad.join(', '));


// --- Daemon-Waechter: Zustandsautomat ---
// Nachbau der Logik aus dem Timer. Der alte Wecker prüfte EINMAL nach 20 s
// und stoppte dann - lief der Daemon in diesem Moment gerade neu an (etwa
// direkt nach einem Update), blieb die Warnung fuer immer falsch stehen.
console.log('--- Daemon-Waechter ---');
function makeWatch() {
  const st = { autostart: true, warned: false, misses: 0, notice: '' };
  st.tick = function(daemonRunning) {
    if (!st.autostart) return;
    if (daemonRunning) {
      st.misses = 0;
      if (st.warned) { st.warned = false; if (st.notice === 'DOWN') st.notice = ''; }
      return;
    }
    st.misses++;
    if (st.misses >= 2 && !st.warned) { st.warned = true; st.notice = 'DOWN'; }
  };
  return st;
}

let w = makeWatch();
w.tick(false);
check('ein Fehlversuch warnt noch nicht', w.notice, v => v === '', 'erwartet Stille nach 20 s');
w.tick(true);
check('Daemon kam hoch -> keine Warnung', w.notice, v => v === '', 'Neustart darf keine Warnung ausloesen');

w = makeWatch();
w.tick(false); w.tick(false);
check('zwei Fehlversuche warnen',    w.notice, v => v === 'DOWN', 'erwartet Warnung nach ~40 s');
w.tick(true);
check('Warnung wird zurueckgenommen', w.notice, v => v === '', 'stehengebliebene Warnung war der gemeldete Fehler');
w.tick(false); w.tick(false);
check('warnt spaeter erneut',        w.notice, v => v === 'DOWN', 'nach echter Erholung muss erneut gewarnt werden koennen');

w = makeWatch(); w.autostart = false;
w.tick(false); w.tick(false); w.tick(false);
check('ohne Autostart nie warnen',   w.notice, v => v === '', 'wer keinen Dienst nutzt, darf keine Warnung sehen');

// --- Orientierungsmaske ---
// Aus der QML-Datei geschnitten: welche Ausrichtung erlaubt welche Einstellung?
console.log('--- Orientierungsmaske ---');
{
  const Orientation = { Portrait: 1, Landscape: 2, All: 15 };
  const maskSrc = grab('orientationMask');
  function mask(pref) {
    return (new Function('Orientation', 'orientationPref',
      maskSrc + '; return orientationMask();'))(Orientation, pref);
  }
  check('dynamisch -> alles',      mask('dynamic'),   v => v === Orientation.All,       'erwartet Orientation.All');
  check('Hochformat fest',         mask('portrait'),  v => v === Orientation.Portrait,  'erwartet Orientation.Portrait');
  check('Querformat fest',         mask('landscape'), v => v === Orientation.Landscape, 'erwartet Orientation.Landscape');
  check('unbekannter Wert -> alles', mask('quatsch'), v => v === Orientation.All,       'Vorgabe muss dynamisch sein');
  check('leerer Wert -> alles',    mask(''),          v => v === Orientation.All,       'Vorgabe muss dynamisch sein');
}

console.log(fails === 0 ? '\nAlle Faelle bestanden.' : '\n' + fails + ' Fall/Faelle fehlgeschlagen.');
process.exit(fails === 0 ? 0 : 1);
