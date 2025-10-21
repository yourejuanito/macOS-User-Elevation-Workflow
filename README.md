# macOS Local Admin Management Scripts

## Overview
This repository provides controlled workflows for managing **local administrator rights** and **command-line sudo access** on macOS devices.

- **Demotion Script** – Removes local admin rights from non-service accounts (per your information security policy).  
- **Elevation Script** – Grants approved users local admin rights permanently (adds to `admin` group).  
- **Sudoers Grant Script** – Grants the currently logged-in user command-line `sudo` privileges, after an explicit security acknowledgment.  

All scripts integrate with **SwiftDialog** for user interaction, maintain audit logs, and enforce safeguards against modifying protected service accounts.

---

## 🚫 Demotion Script

### Purpose
- Removes local administrator rights from user accounts.
- Leaves service/management accounts elevated (e.g. `Administrator`, `administrator`, `jamf`, `root`).
- Supports **Information Security requirement** to enforce the principle of least privilege.

### How It Works
1. Enumerates local accounts with `UID ≥ 501`.  
2. Excludes protected accounts.  
3. Iterates through users and removes them from the `admin` group.  

### Logging & Audit
- Logs actions to:  
  ```
  /var/log/user-demotions.log
  ```
- Optional: Can export results back to Jamf via Extension Attribute for reporting.

---

## ⬆️ Elevation Script

### Purpose
- Permanently elevates a **local macOS user** to the `admin` group.  
- Intended for **Service Desk / IT staff** to run **only after approvals** from your appropriate parties.  
- Uses **SwiftDialog** to prompt for username + request number, with a mandatory acknowledgment.  

### How It Works
1. Detects the currently logged-in console user.  
2. Prompts operator with a **SwiftDialog form**:  
   - Username (must be a local account, UID ≥ 501)  
   - Request number (must match `REQ-######`)  
   - Security acknowledgment  
3. Retries up to 3 times if acknowledgment is not given. Cancel exits immediately.  
4. Adds user to the `admin` group.  
5. Logs full details for audit.  

### Logging & Audit
- Logs to:  
  ```
  /var/log/user-elevations.log
  ```
- Audit CSV written to:  
  ```
  /Library/Management/AdminElevation/audit.csv
  ```
- Example entry:
  ```
  2025-10-03 09:22:12,john.doe,jdoe,REQ-123456,add_to_admin,success
  ```

---

## 💻 Sudoers CLI Grant Script

### Purpose
- Grants the **currently logged-in user** the ability to run `sudo` commands at the command line.  
- Uses a **separate sudoers file** under `/etc/sudoers.d/<username>` instead of modifying `/etc/sudoers` directly.  
- Safer, reversible, and validated with `visudo`.  

### How It Works
1. Detects the console user (`UID ≥ 501`).  
2. Prompts with **SwiftDialog security warning**:  
   - Explicit warning of risks.  
   - Required acknowledgment checkbox.  
   - Retries up to 3 times if unchecked.  
   - Cancel exits immediately.  
3. Creates `/etc/sudoers.d/<username>` with:  
   ```
   <username> ALL=(ALL) NOPASSWD: ALL
   ```
   *(or with password prompt if modified)*  
4. Validates syntax with `visudo -c` before applying.  
5. Logs the action and writes to audit CSV.  

### Logging & Audit
- Logs to:  
  ```
  /var/log/sudoers-grants.log
  ```
- Audit CSV written to:  
  ```
  /Library/Management/AdminElevation/sudoers-audit.csv
  ```
- Example entry:
  ```
  2025-10-03 09:35:45,john.doe,jdoe,grant_sudo,success
  ```

---

## ⚙️ Configuration

- **Protected Accounts** (never modified by these workflows):  
  ```
  administrator, Administrator, jamf, Jamf, root
  ```
- **Dialog Binary:**  
  ```
  /usr/local/bin/dialog
  ```
  > Ensure [SwiftDialog](https://github.com/bartreardon/swiftDialog) is installed.

---

## 🔐 Security Features

- **Demotion Script**: prevents accidental demotion of service accounts.  
- **Elevation Script**: requires both username + valid incident number (`REQ-######`) + security acknowledgment.  
- **Sudoers Grant Script**: validates sudoers entries with `visudo` and requires explicit acknowledgment.  
- All actions are logged and auditable.  

---

## 📖 Example Workflows

### Demotion (Policy)
```bash
sudo ./demote-users.sh
```
- Removes local admin rights from all non-protected accounts. There is no user interactivity as this would be done in a remediation workflow. 

	***protected accounts are controlled in line 30 of the script.*** 


### Elevation (Service Desk)
```bash
sudo ./elevate-user.sh
```
- Prompts for username + request.  
- Requires acknowledgment.  
- Adds user to `admin` group.  

	#### Dialogs of scripts once ran. 

	Initial prompt the user gets once the script successfully runs. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image1.png?token=GHSAT0AAAAAADNMR5E64CWS3NSHFKAMZLCI2HW2BVQ)
 
	If the user enters the REQ number incorrectly or not exactly to what is specified in the script. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image2.png?token=GHSAT0AAAAAADNMR5E67SFLNHNYMTUA4BJS2HW2CGA)

	Elevation confirmation prompt when the user is promoted. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image3.png?token=GHSAT0AAAAAADNMR5E6NV3LO6A6RIS7BEPI2HW2CXQ)

	Prompt user gets when the specified user in the initial prompt is already and administrator. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image4.png?token=GHSAT0AAAAAADNMR5E6466NJE6FCXM3QQOW2HW2DAQ)

### Sudoers CLI Grant (Service Desk / Advanced)
```bash
sudo ./elevate-user-cli.sh
```
- Prompts with security warning.  
- Requires acknowledgment.  
- Grants logged-in user CLI `sudo` rights.  

	#### Dialog prompts when CLI provilges are granted. 
	
	Initial prompt the user sees when the script runs. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image2-1.png?token=GHSAT0AAAAAADNMR5E7TXJT6OB7VJFZ654K2HW2EYQ)
	
	If user does not check-off the checkbox they will get this error prompt. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image2-2.png?token=GHSAT0AAAAAADNMR5E7GSGRRHUIMCUN43G42HW2DOQ)
	
	Prompt displayed once the user has been granted access. 
	![](https://raw.githubusercontent.com/yourejuanito/macOS-User-Elevation-Workflow/refs/heads/main/images/image2-3.png?token=GHSAT0AAAAAADNMR5E7UUL6H54JTJIRPDJQ2HW2DHQ)

---




## Disclaimer
These scripts are intended for internal IT workflows.  
They should be used only by authorized personnel **after proper approvals**.
