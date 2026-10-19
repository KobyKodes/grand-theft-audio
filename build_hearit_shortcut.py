#!/usr/bin/env python3
"""Builds "Grand Theft Audio.shortcut" with every script packed inside it.

Run after changing any of the scripts. HearItOwnIt.applescript ships compiled run-only.
The progress window (ytprogress.swift) is compiled here when it's missing or out of
date, which needs Xcode's command line tools (xcode-select --install). Without them
the shortcut still works, just without the window.

The shortcut:
  1. Text: the scripts (base64 tar.gz)
  2. Run Shell Script: hearit_setup.sh, stdin = 1   (unpacks / installs tools)
  3. Run Shell Script: hearit_listen.sh              (orb window, listening)
  4. Shazam it, hidden (the orb window shows instead of Shazam's pop-up)
  5. Text: <Artist>|<Title>
  6. Run AppleScript: HearItOwnIt-launcher.applescript, input = 5
"""
import base64
import io
import os
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
COPIED = ["hearit.sh", "ytmusic.sh", "update_ytdlp.sh", "tag_m4a.py", "hearit.py", "find_python.sh", "ytprogress", "sounds/owned.wav", "sounds/owned2.wav"]
OUT = os.path.join(HERE, "Grand Theft Audio (Redesign).shortcut")


def read(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def build_ytprogress() -> bool:
    """Compiles the progress window (Intel + Apple Silicon, macOS 12+) if it's missing or
    older than its source. Returns False if it can't be built."""
    binary, src = os.path.join(HERE, "ytprogress"), os.path.join(HERE, "ytprogress.swift")
    if os.path.exists(binary) and os.path.getmtime(binary) >= os.path.getmtime(src):
        return True
    if subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True).returncode != 0:
        print("No Swift compiler (xcode-select --install): building without the progress window.")
        return False
    with tempfile.TemporaryDirectory() as tmp:
        slices = []
        for arch in ("arm64", "x86_64"):
            slices.append(os.path.join(tmp, arch))
            subprocess.run(["xcrun", "swiftc", "-O", "-target", f"{arch}-apple-macos12", src, "-o", slices[-1]],
                           check=True)
        subprocess.run(["lipo", "-create", *slices, "-o", binary], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", binary], check=True, capture_output=True)
    return True


def stage(out):
    """Writes the files that go inside the shortcut into the folder `out`."""
    src = os.path.join(HERE, "HearItOwnIt.applescript")
    subprocess.run(["osacompile", "-x", "-o", os.path.join(out, "HearItOwnIt.scpt"), src], check=True)

    names = COPIED if build_ytprogress() else [n for n in COPIED if n != "ytprogress"]
    for name in names:  # keeps subfolders (sounds/), same layout as this folder
        os.makedirs(os.path.dirname(os.path.join(out, name)), exist_ok=True)
        shutil.copy2(os.path.join(HERE, name), os.path.join(out, name))


def bundle() -> str:
    buf = io.BytesIO()
    with tempfile.TemporaryDirectory() as staged:
        stage(staged)
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            names = sorted(os.path.relpath(os.path.join(d, f), staged)
                           for d, _, files in os.walk(staged) for f in files)
            for name in names:
                info = tar.gettarinfo(os.path.join(staged, name), arcname=name)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0  # same files → same bundle → setup skips re-unpacking
                with open(os.path.join(staged, name), "rb") as f:
                    tar.addfile(info, f)
    return base64.b64encode(buf.getvalue()).decode()


def new_id():
    return str(uuid.uuid4()).upper()


def output(action_id, name, prop=None):
    ref = {"Type": "ActionOutput", "OutputUUID": action_id, "OutputName": name}
    if prop:
        ref["Aggrandizements"] = [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": prop}]
    return ref


def main():
    shazam, song, files, setup, listen, run = (new_id() for _ in range(6))
    actions = [
        {"WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
         "WFWorkflowActionParameters": {"UUID": files, "CustomOutputName": "Script Files",
                                        "WFTextActionText": bundle()}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript",
         "WFWorkflowActionParameters": {
             "UUID": setup, "Shell": "/bin/bash", "InputMode": "to stdin", "RunAsRoot": False,
             "Script": read("hearit_setup.sh"),
             "Input": {"Value": output(files, "Script Files"), "WFSerializationType": "WFTextTokenAttachment"}}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript",
         "WFWorkflowActionParameters": {
             "UUID": listen, "Shell": "/bin/bash", "InputMode": "to stdin", "RunAsRoot": False,
             "Script": read("hearit_listen.sh")}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.shazamMedia",
         "WFWorkflowActionParameters": {"UUID": shazam, "WFShazamMediaActionShowWhenRun": False,
                                        "WFShazamMediaActionErrorIfNotRecognized": False}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
         "WFWorkflowActionParameters": {"UUID": song, "CustomOutputName": "Song", "WFTextActionText": {
             "Value": {"string": "￼|￼", "attachmentsByRange": {
                 "{0, 1}": output(shazam, "Shazam Media", "Artist"),
                 "{2, 1}": output(shazam, "Shazam Media", "Title")}},
             "WFSerializationType": "WFTextTokenString"}}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.runapplescript",
         "WFWorkflowActionParameters": {
             "UUID": run, "Script": read("HearItOwnIt-launcher.applescript"),
             "Input": {"Value": output(song, "Song"), "WFSerializationType": "WFTextTokenAttachment"}}},
    ]
    workflow = {
        "WFWorkflowClientVersion": "2607.0.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4292093695, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": ["MenuBar"],
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
