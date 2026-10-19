#!/usr/bin/env python3
"""Builds "Hear it Later.shortcut", the iPhone half of Hear it → Own it.

On the iPhone it Shazams a song, asks which playlist it should go in (your recent
Mac playlists, from iCloud Drive → Shortcuts → HearIt/playlists.txt), and saves
"Artist|Title|Playlist" as HearIt/Queue/<timestamp>.txt. The Mac picks it up with
hearit_queue.sh (see install_hearit_queue.sh).

Run it, then open the .shortcut on the Mac and add it; it syncs to the iPhone.
Optional: the main shortcut works without it.

The shortcut:
  1. Shazam it (stops with an error if nothing is recognized)
  2. Get File HearIt/playlists.txt from the Shortcuts folder
  3. Text: No playlist / New playlist… / <playlists>, split into lines
  4. Choose from List
  5. If "New playlist…": Ask for a name. Either way → variable Playlist
  6. Save "Artist|Title|Playlist" to HearIt/Queue/<yyyyMMdd-HHmmss>.txt
  7. If on Wi-Fi, look the network up in HearIt/wifi.txt. The first time on a network
     it asks "Is your Mac on this Wi-Fi?" and remembers the answer there
     (lines "yes⟦name⟧" / "no⟦name⟧"; edit the file in the Files app to change one).
  8. On a "yes" network: Run Script Over SSH → hearit_now.sh on this Mac, so the
     download starts now. The iCloud file from step 6 stays as the backup; the Mac
     skips it once the song is in (see hearit_queue.sh).
  9. Notification

The SSH step signs in with a key the iPhone makes. One-time setup: turn on Remote
Login on the Mac, then on the iPhone open the shortcut, tap the SSH action →
SSH Key → Share Public Key, and add that line to ~/.ssh/authorized_keys on the Mac.
Mac name and user default to this Mac (HEARIT_SSH_HOST / HEARIT_SSH_USER override).
"""
import getpass
import json
import os
import plistlib
import shlex
import subprocess
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "Hear it Later.shortcut")
NO_PLAYLIST = "No playlist"       # same labels as HearItOwnIt.applescript
NEW_PLAYLIST = "New playlist…"
MAC_YES = "Yes, send songs straight to it"
MAC_NO = "No, just use iCloud"
OBJ = "￼"  # where a variable goes inside a text field

# The "Shortcuts" folder in iCloud Drive, as the Shortcuts app stores it. The app finds
# it by type; the two iCloud IDs it also records belong to one iCloud account, so they
# come from hearit_later.local.json if you have one (not committed), else are left out.
SHORTCUTS_FOLDER = {
    "fileLocation": {
        "appContainerBundleIdentifier": "com.apple.systemactions",
        "relativeSubpath": "",
        "WFFileLocationType": "Shortcuts",
    },
    "filename": "Documents",
    "displayName": "Shortcuts",
}
try:
    with open(os.path.join(HERE, "hearit_later.local.json"), encoding="utf-8") as f:
        SHORTCUTS_FOLDER["fileLocation"].update(json.load(f))
except FileNotFoundError:
    pass


def new_id():
    return str(uuid.uuid4()).upper()


def output(action_id, name, prop=None):
    ref = {"Type": "ActionOutput", "OutputUUID": action_id, "OutputName": name}
    if prop:
        ref["Aggrandizements"] = [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": prop}]
    return ref


def variable(name):
    return {"Type": "Variable", "VariableName": name}


def attachment(ref):
    """A whole parameter that is just one variable."""
    return {"Value": ref, "WFSerializationType": "WFTextTokenAttachment"}


def text(*parts):
    """A text field mixing plain strings and variables (dicts)."""
    s, attachments = "", {}
    for p in parts:
        if isinstance(p, dict):
            attachments[f"{{{len(s)}, 1}}"] = p
            s += OBJ
        else:
            s += p
    return {"Value": {"string": s, "attachmentsByRange": attachments}, "WFSerializationType": "WFTextTokenString"}


def action(ident, **params):
    return {"WFWorkflowActionIdentifier": f"is.workflow.actions.{ident}", "WFWorkflowActionParameters": params}


def condition(group, value, test, string=None):
    """Start of an If block. test: 4 is, 99 contains, 999 does not contain, 100 has any value."""
    params = dict(GroupingIdentifier=group, WFControlFlowMode=0, WFCondition=test,
                  WFInput={"Type": "Variable", "Variable": attachment(value)})
    if string is not None:
        params["WFConditionalActionString"] = string
    return action("conditional", **params)


def otherwise(group):
    return action("conditional", GroupingIdentifier=group, WFControlFlowMode=1)


def end_if(group):
    return action("conditional", GroupingIdentifier=group, WFControlFlowMode=2)


def mac_host():
    if os.environ.get("HEARIT_SSH_HOST"):
        return os.environ["HEARIT_SSH_HOST"]
    name = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True, check=True)
    return name.stdout.strip() + ".local"  # Bonjour name: works on any shared Wi-Fi without an IP


def main():
    shazam, getfile, options, split, choose, ask, date, line, save = (new_id() for _ in range(9))
    group = new_id()
    wifi, known, known_as_text, save_yes, save_no, fast_input, ssh = (new_id() for _ in range(7))
    on_wifi, is_yes, not_no, ask_menu, send = (new_id() for _ in range(5))
    network = output(wifi, "Network Details")
    known_file = output(known, "File")
    # An If needs a value to test, and on the first run wifi.txt doesn't exist yet,
    # so the checks look at this text (a fixed first line + the file), never empty.
    known_text = output(known_as_text, "Text")
    def set_send(answer):  # SendToMac is "yes" or "no", always set: an If can't test an empty variable
        t = new_id()
        return [action("gettext", UUID=t, WFTextActionText=text(answer)),
                action("setvariable", WFVariableName="SendToMac", WFInput=attachment(output(t, "Text")))]

    remember = lambda answer: text(known_file, f"{answer}⟦", network, "⟧\n")  # noqa: E731
    wifi_file = text("HearIt/wifi.txt")
    artist = output(shazam, "Shazam Media", "Artist")
    title = output(shazam, "Shazam Media", "Title")

    actions = [
        action("shazamMedia", UUID=shazam, WFShazamMediaActionShowWhenRun=True,
               WFShazamMediaActionErrorIfNotRecognized=True),

        action("documentpicker.open", UUID=getfile, WFFile=SHORTCUTS_FOLDER,
               WFGetFilePath="HearIt/playlists.txt", WFFileErrorIfNotFound=False),
        action("gettext", UUID=options,
               WFTextActionText=text(f"{NO_PLAYLIST}\n{NEW_PLAYLIST}\n", output(getfile, "File"))),
        action("text.split", UUID=split, WFTextSeparator="New Lines",
               text=attachment(output(options, "Text"))),
        action("choosefromlist", UUID=choose, WFInput=attachment(output(split, "Split Text")),
               WFChooseFromListActionPrompt=text("Add ", title, " to a playlist?")),

        action("conditional", GroupingIdentifier=group, WFControlFlowMode=0, WFCondition=4,
               WFConditionalActionString=NEW_PLAYLIST,
               WFInput={"Type": "Variable", "Variable": attachment(output(choose, "Chosen Item"))}),
        action("ask", UUID=ask, WFInputType="Text", WFAskActionPrompt="Name for the new playlist"),
        action("setvariable", WFVariableName="Playlist", WFInput=attachment(output(ask, "Provided Input"))),
        action("conditional", GroupingIdentifier=group, WFControlFlowMode=1),
        action("setvariable", WFVariableName="Playlist", WFInput=attachment(output(choose, "Chosen Item"))),
        action("conditional", GroupingIdentifier=group, WFControlFlowMode=2),

        action("format.date", UUID=date, WFDateFormatStyle="Custom", WFDateFormat="yyyyMMdd-HHmmss",
               WFDate=text({"Type": "CurrentDate"})),
        action("gettext", UUID=line, WFTextActionText=text(artist, "|", title, "|", variable("Playlist"))),
        action("documentpicker.save", UUID=save, WFInput=attachment(output(line, "Text")),
               WFAskWhereToSave=False, WFSaveFileOverwrite=True,
               WFFileDestinationPath=text("HearIt/Queue/", output(date, "Formatted Date"), ".txt")),


        # ---- Wi-Fi fast lane ----
        *set_send("no"),
        action("getwifi", UUID=wifi, WFNetworkDetailsNetwork="Wi-Fi", WFWiFiDetail="Network Name"),
        condition(on_wifi, network, 100),
        action("documentpicker.open", UUID=known, WFFile=SHORTCUTS_FOLDER,
               WFGetFilePath="HearIt/wifi.txt", WFFileErrorIfNotFound=False),
        action("gettext", UUID=known_as_text, WFTextActionText=text("Wi-Fi networks:\n", known_file)),
        condition(is_yes, known_text, 99, text("yes⟦", network, "⟧")),
        *set_send("yes"),
        otherwise(is_yes),
        condition(not_no, known_text, 999, text("no⟦", network, "⟧")),
        action("choosefrommenu", GroupingIdentifier=ask_menu, WFControlFlowMode=0,
               WFMenuPrompt=text("Is your Mac on the Wi-Fi “", network, "” too? Songs then start downloading right away."),
               WFMenuItems=[MAC_YES, MAC_NO]),
        action("choosefrommenu", GroupingIdentifier=ask_menu, WFControlFlowMode=1, WFMenuItemTitle=MAC_YES),
        action("gettext", UUID=save_yes, WFTextActionText=remember("yes")),
        action("documentpicker.save", WFInput=attachment(output(save_yes, "Text")), WFAskWhereToSave=False,
               WFSaveFileOverwrite=True, WFFileDestinationPath=wifi_file),
        *set_send("yes"),
        action("choosefrommenu", GroupingIdentifier=ask_menu, WFControlFlowMode=1, WFMenuItemTitle=MAC_NO),
        action("gettext", UUID=save_no, WFTextActionText=remember("no")),
        action("documentpicker.save", WFInput=attachment(output(save_no, "Text")), WFAskWhereToSave=False,
               WFSaveFileOverwrite=True, WFFileDestinationPath=wifi_file),
        action("choosefrommenu", GroupingIdentifier=ask_menu, WFControlFlowMode=2),
        end_if(not_no),
        end_if(is_yes),
        end_if(on_wifi),

        condition(send, variable("SendToMac"), 4, "yes"),
        action("gettext", UUID=fast_input,
               WFTextActionText=text(output(date, "Formatted Date"), ".txt\n", output(line, "Text"))),
        action("runsshscript", UUID=ssh, WFSSHHost=mac_host(), WFSSHPort="22",
               WFSSHUser=os.environ.get("HEARIT_SSH_USER") or getpass.getuser(),
               WFSSHAuthenticationType="SSH Key",
               WFSSHScript=shlex.quote(os.path.join(HERE, "hearit_now.sh")),
               WFInput=attachment(output(fast_input, "Text"))),
        action("notification", WFNotificationActionTitle="Downloading on your Mac",
               WFNotificationActionBody=text(title, " — ", artist), WFNotificationActionSound=False),
        otherwise(send),
        action("notification", WFNotificationActionTitle="Saved for your Mac",
               WFNotificationActionBody=text(title, " — ", artist), WFNotificationActionSound=False),
        end_if(send),
    ]
    workflow = {
        "WFWorkflowClientVersion": "2607.0.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowActions": actions,
    }
    with tempfile.TemporaryDirectory() as tmp:
        unsigned = os.path.join(tmp, "unsigned.shortcut")
        with open(unsigned, "wb") as f:
            plistlib.dump(workflow, f)
        subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", OUT],
                       check=True, stderr=subprocess.DEVNULL)
    print(OUT)


if __name__ == "__main__":
    main()
