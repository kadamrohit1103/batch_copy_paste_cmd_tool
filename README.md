# Batch Copy Tool - User Guide

A command-line tool to copy files from a list, renaming them on the fly if needed, and handling duplicates automatically.

## Installation
Ensure `copy_tool.bat` and `BatchCopier.ps1` are in the same folder (e.g., `C:\Apps\BatchCopier`).

## Usage
Run the tool from Command Prompt (CMD):
```cmd
copy_tool.bat [YourList.csv] [options]
```

### Options
- `-dryrun`: **Recommended!** Previews what will happen without copying files.
- `-undo`: Deletes the files that were copied in the last run.

### CSV Format
Your CSV file should have 2 or 3 columns.
- **Column 1**: Source File Path (Full path)
- **Column 2**: Destination Folder
- **Column 3**: (Optional) New Filename

**Example CSV:**
```csv
Source Path,Destination,New Name
D:\Photos\IMG_001.jpg,D:\Backup\2024,
D:\Docs\report.pdf,D:\Backup\Docs,final_report.pdf
D:\Docs\notes.txt,D:\Backup\Docs,
```

### Behaviors
1.  **Auto-Renaming**: If you copy `notes.txt` to a folder that already has `notes.txt`, the tool automatically saves it as `notes_1.txt` (then `notes_2.txt`, etc.).
2.  **Optional Renaming**: If you provide a name in Column 3 (e.g., `final_report.pdf`), it uses that name instead of the original.
