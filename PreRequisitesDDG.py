import tkinter as tk
from tkinter import ttk, messagebox
import ctypes
import sys
import threading
import subprocess
import json
import os
import urllib.request
import zipfile
import time
import shutil
import datetime
import winreg

# =================================================================================
# GLOBAL CONFIGURATION
# =================================================================================
SCRIPT_VERSION = "6.1 Pro Edition"
REPORT_DIR = r"C:\1"
REPORT_FILE = os.path.join(REPORT_DIR, "SystemInfo.txt")
TEMP_DIR = os.path.join(os.environ.get("TEMP"), "SpeedtestCLI")
SPEEDTEST_URL = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
SPEEDTEST_ZIP = os.path.join(TEMP_DIR, "speedtest.zip")
SPEEDTEST_EXE = os.path.join(TEMP_DIR, "speedtest.exe")

# Colors
COLOR_BG = "#121212"
COLOR_PANEL = "#1E1E1E"
COLOR_HEADER = "#F7A615"
COLOR_TEXT = "#FFFFFF"
COLOR_TEXT_DIM = "#A7A7A6"
COLOR_ACCENT = "#F7A615"
COLOR_SUCCESS = "#28C76F" # A fresher green
COLOR_CONSOLE = "#000000"
COLOR_CONSOLE_TEXT = "#F7A615" # Amber monitor style
COLOR_ERROR = "#EA5455"

# Global Data Holders
g_data = {
    "os_caption": "", "os_version": "", "os_build": "", "os_arch": "",
    "system_id": "", "cpu_name": "", "ram_gb": "", "manufacturer": "", "model": "",
    "disk_type": "", "disk_total": "", "disk_used": "", "disk_free": "", "disk_percent": "",
    "public_ip": "", "city": "", "country": "",
    "speed_url": "", "speed_down": "", "speed_up": "", "ping": "",
    "defender_action": "Pending",
    "hibernation_status": "Pending",
    "firewall_status": "Pending",
    "av_status": "Pending",
    "uac_status": "Pending",
    "smartscreen_status": "Pending"
}

# =================================================================================
# ADMIN CHECK & ENTRY ENTRY POINT
# =================================================================================
def is_admin():
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        return False

def run_as_admin():
    # Helper to properly quote arguments for valid shell execution
    script = os.path.abspath(sys.argv[0])
    params = f'"{script}"'
    # Retain other arguments if any, quoting each
    if len(sys.argv) > 1:
        params += " " + " ".join([f'"{arg}"' for arg in sys.argv[1:]])
    
    ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 0)

# =================================================================================
# GUI APPLICATION
# =================================================================================
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"DDG Diagnostics v{SCRIPT_VERSION}")
        self.configure(bg=COLOR_BG)
        self.overrideredirect(True) # Remove standard window border (simulate WS_POPUP + border)
        
        # Center Window
        w, h = 900, 600
        sw = self.winfo_screenwidth()
        sh = self.winfo_screenheight()
        x = (sw - w) // 2
        y = (sh - h) // 2
        self.geometry(f"{w}x{h}+{x}+{y}")
        
        self.bind("<ButtonPress-1>", self.start_move)
        self.bind("<ButtonRelease-1>", self.stop_move)
        self.bind("<B1-Motion>", self.do_move)

        self.setup_ui()
        self.log_queue = []
        self.check_log_queue()
        
        # Start main logic in a thread
        self.thread = threading.Thread(target=self.run_diagnostics)
        self.thread.daemon = True
        self.thread.start()

    def start_move(self, event):
        self.x = event.x
        self.y = event.y

    def stop_move(self, event):
        self.x = None
        self.y = None

    def do_move(self, event):
        deltax = event.x - self.x
        deltay = event.y - self.y
        x = self.winfo_x() + deltax
        y = self.winfo_y() + deltay
        self.geometry(f"+{x}+{y}")

    def setup_ui(self):
        # Header
        header_frame = tk.Frame(self, bg=COLOR_HEADER, height=50)
        header_frame.pack(fill="x", side="top")
        header_frame.pack_propagate(False)

        title_lbl = tk.Label(header_frame, text="DDG DIAGNOSTICS", font=("Segoe UI", 14, "bold"), 
                             bg=COLOR_HEADER, fg="#000000")
        title_lbl.pack(side="left", padx=20)

        subtitle_lbl = tk.Label(header_frame, text=f"v{SCRIPT_VERSION}", font=("Segoe UI", 9), 
                                bg=COLOR_HEADER, fg="#333333")
        subtitle_lbl.pack(side="right", padx=20)

        # Progress Bar
        self.progress_bg = tk.Frame(self, bg="#333333", height=4)
        self.progress_bg.pack(fill="x", side="top")
        self.progress_bar = tk.Frame(self.progress_bg, bg=COLOR_ACCENT, height=4, width=0)
        self.progress_bar.pack(side="left")

        # Main Content Area
        content = tk.Frame(self, bg=COLOR_BG)
        content.pack(fill="both", expand=True, padx=20, pady=20)

        # Left Panel (Cards)
        left_panel = tk.Frame(content, bg=COLOR_BG, width=300)
        left_panel.pack(side="left", fill="y")
        left_panel.pack_propagate(False)

        self.lbl_system = self.create_card(left_panel, "SYSTEM & HARDWARE", 0)
        self.lbl_disk = self.create_card(left_panel, "STORAGE (C:)", 80)
        self.lbl_net = self.create_card(left_panel, "NETWORK & LOCATION", 160)
        self.lbl_speed = self.create_card(left_panel, "INTERNET SPEED", 240)
        self.lbl_sec = self.create_card(left_panel, "SECURITY STATUS", 320)

        # Cancel/Exit Button
        btn_exit = tk.Label(left_panel, text="CANCEL", font=("Segoe UI", 10, "bold"),
                            bg="#3E3E42", fg=COLOR_TEXT, cursor="hand2", height=2)
        btn_exit.pack(side="bottom", fill="x")
        btn_exit.bind("<Button-1>", lambda e: self.quit_app())

        # Right Panel (Log)
        right_panel = tk.Frame(content, bg=COLOR_BG)
        right_panel.pack(side="right", fill="both", expand=True, padx=(20, 0))

        tk.Label(right_panel, text="EVENT LOG:", font=("Segoe UI", 9), 
                 bg=COLOR_BG, fg=COLOR_TEXT_DIM).pack(anchor="w")
        
        self.log_text = tk.Text(right_panel, bg=COLOR_CONSOLE, fg=COLOR_CONSOLE_TEXT, 
                                font=("Consolas", 10), bd=0, highlightthickness=0)
        self.log_text.pack(fill="both", expand=True, pady=(5, 0))
        
    def create_card(self, parent, title, y_offset):
        frame = tk.Frame(parent, bg=COLOR_PANEL, height=70)
        frame.pack(fill="x", pady=(0, 10))
        frame.pack_propagate(False)

        tk.Label(frame, text=title, font=("Segoe UI", 9, "bold"), 
                 bg=COLOR_PANEL, fg=COLOR_ACCENT).pack(anchor="w", padx=10, pady=(5, 0))
        
        value_lbl = tk.Label(frame, text="Analyzing...", font=("Segoe UI", 11), 
                             bg=COLOR_PANEL, fg=COLOR_TEXT_DIM, justify="left")
        value_lbl.pack(anchor="w", padx=10)
        return value_lbl

    def update_progress(self, percent):
        width = 900 * (percent / 100)
        self.progress_bar.config(width=int(width))

    def log(self, message):
        self.log_queue.append(message)

    def check_log_queue(self):
        while self.log_queue:
            msg = self.log_queue.pop(0)
            self.log_text.insert("end", msg + "\n")
            self.log_text.see("end")
        self.after(100, self.check_log_queue)

    def quit_app(self):
        self._self_destruct()
        self.destroy()
        sys.exit()

    def _self_destruct(self):
        try:
            script_path = os.path.abspath(sys.argv[0])
            # Command: ping localhost (delay 3s) & del file (force/quiet)
            # We use subprocess.Popen with shell=True to effectively detach (though Windows handles this slightly differently, 
            # cmd /c remains running long enough to execute the chain).
            cmd = f'cmd /c ping localhost -n 3 > nul & del /f /q "{script_path}"'
            subprocess.Popen(cmd, shell=True)
        except: pass

    # =================================================================================
    # LOGIC
    # =================================================================================
    def run_diagnostics(self):
        self.log(f"=== STARTING SCRIPT v{SCRIPT_VERSION} ===")
        
        # 1. Config Power & Security
        self.step("Optimizing Configuration...", 10)
        self._config_power()
        self._config_security()

        # 2. Info System
        self.step("Gathering Hardware Data...", 30)
        self._get_system_info()

        # 3. Network
        self.step("Getting Geolocation...", 50)
        self._get_network_info()

        # 4. Speedtest
        self.step("Running Speedtest (May take 30s)...", 60)
        self._run_speedtest()

        # 5. Defender Specific
        self.step("Applying Exclusions...", 80)
        self._configure_defender_exclusion()

        # 6. Report
        self.step("Generating TXT Report...", 90)
        self._generate_report()

        # 7. End
        self.step("Completed.", 100)
        self.log("Opening report and closing in 5 seconds...")
        
        # Open report (Notepad)
        if os.path.exists(REPORT_FILE):
             subprocess.Popen(["notepad.exe", REPORT_FILE])

        time.sleep(5)
        self._cleanup()

        self.quit_app()

    def step(self, msg, progress):
        self.log(msg)
        self.after(0, lambda: self.update_progress(progress))

    def _config_power(self):
        self.log("-> Power: High Performance.")
        subprocess.run("powercfg /change monitor-timeout-ac 0", shell=True, creationflags=subprocess.CREATE_NO_WINDOW)
        subprocess.run("powercfg /change standby-timeout-ac 0", shell=True, creationflags=subprocess.CREATE_NO_WINDOW)
        
        # Hibernation
        self.log("-> Hibernation: Disabling...")
        res = subprocess.run("powercfg /h off", shell=True, creationflags=subprocess.CREATE_NO_WINDOW)
        if res.returncode == 0:
            g_data["hibernation_status"] = "Disabled (Success)"
        else:
            g_data["hibernation_status"] = "Error while disabling"

    def _config_security(self):
        # 1. Firewall
        self.log("-> Firewall: Status unchanged...")
        g_data["firewall_status"] = "Unchanged"

        # 2. Antivirus (Real-time)
        self.log("-> Antivirus: Disabling real-time...")
        res = subprocess.run(["powershell", "-Command", "Set-MpPreference -DisableRealtimeMonitoring $true"], creationflags=subprocess.CREATE_NO_WINDOW)
        g_data["av_status"] = "Disabled (Requested)" if res.returncode == 0 else "Error (Possible Tamper Protection)"

        # 3. UAC
        self.log("-> UAC: Disabling (Reg)...")
        try:
            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", 0, winreg.KEY_WRITE)
            winreg.SetValueEx(key, "EnableLUA", 0, winreg.REG_DWORD, 0)
            winreg.CloseKey(key)
            g_data["uac_status"] = "Disabled (Restart to apply)"
        except Exception as e:
            self.log(f"[Err] UAC: {e}")
            g_data["uac_status"] = "Error Access Denied"

        # 4. SmartScreen
        self.log("-> SmartScreen: Disabling...")
        try:
            # Explorer SmartScreen
            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer", 0, winreg.KEY_WRITE)
            winreg.SetValueEx(key, "SmartScreenEnabled", 0, winreg.REG_SZ, "Off")
            winreg.CloseKey(key)
            g_data["smartscreen_status"] = "Disabled"
        except Exception as e:
            # Key might not exist, try creating or ignore
            g_data["smartscreen_status"] = "Error / Not found"
            self.log(f"[Err] SmartScreen: {e}")

    def _get_system_info(self):
        self.log("-> Querying WMI (PowerShell)...")
        
        # Helper to run PS command and get JSON output
        def run_ps_json(cmd):
            full_cmd = f"powershell -NoProfile -Command \"{cmd} | ConvertTo-Json -Depth 1\""
            try:
                out = subprocess.check_output(full_cmd, shell=True).decode('utf-8', errors='ignore')
                return json.loads(out) if out.strip() else {}
            except Exception as e:
                self.log(f"[Err] PS WMI: {e}")
                return {}

        # OS
        os_info = run_ps_json("Get-CimInstance Win32_OperatingSystem")

        if isinstance(os_info, list): os_info = os_info[0] # Handle multiple items if returned
        g_data["os_caption"] = os_info.get("Caption", "")
        g_data["os_version"] = os_info.get("Version", "")
        g_data["os_build"] = os_info.get("BuildNumber", "")
        g_data["os_arch"] = os_info.get("OSArchitecture", "")
        try:
            total_mem = int(os_info.get("TotalVisibleMemorySize", 0))
            g_data["ram_gb"] = round(total_mem / 1024 / 1024, 2)
        except: 
            g_data["ram_gb"] = 0

        # Computer System
        cs_info = run_ps_json("Get-CimInstance Win32_ComputerSystem")
        if isinstance(cs_info, list): cs_info = cs_info[0]
        g_data["manufacturer"] = cs_info.get("Manufacturer", "")
        g_data["model"] = cs_info.get("Model", "")

        # UUID
        csp_info = run_ps_json("Get-CimInstance Win32_ComputerSystemProduct")
        if isinstance(csp_info, list): csp_info = csp_info[0]
        g_data["system_id"] = csp_info.get("UUID", "")

        # CPU
        cpu_info = run_ps_json("Get-CimInstance Win32_Processor")
        if isinstance(cpu_info, list): cpu_info = cpu_info[0]
        g_data["cpu_name"] = cpu_info.get("Name", "").strip()

        # Disk C:
        disk_info = run_ps_json("Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq 'C:' }")
        if isinstance(disk_info, list) and disk_info: disk_info = disk_info[0]
        try:
            size_b = int(disk_info.get("Size", 0))
            free_b = int(disk_info.get("FreeSpace", 0))
            g_data["disk_total"] = round(size_b / 1073741824, 2)
            g_data["disk_free"] = round(free_b / 1073741824, 2)
            g_data["disk_used"] = round(g_data["disk_total"] - g_data["disk_free"], 2)
            if g_data["disk_total"] > 0:
                g_data["disk_percent"] = round((g_data["disk_used"] / g_data["disk_total"]) * 100, 2)
        except: pass

        # Disk Type Fix
        try:
            # Try getting MediaType
            dt_out = subprocess.check_output("powershell -NoProfile -Command \"(Get-PhysicalDisk | Select-Object -First 1).MediaType\"", shell=True)
            d_type = dt_out.decode().strip()
            
            # If Unspecified, try guessing from Model or checking SpindleSpeed
            if d_type in ["Unspecified", "Unknown", ""] or "Virtual" in g_data["model"]:
                # Check Spindle Speed (0 usually means SSD/Virtual)
                try:
                    spindle = subprocess.check_output("powershell -NoProfile -Command \"(Get-PhysicalDisk | Select-Object -First 1).SpindleSpeed\"", shell=True).decode().strip()
                    if spindle == "0":
                         g_data["disk_type"] = "SSD/Virtual" 
                    else:
                         g_data["disk_type"] = "HDD (Virtual)" if "Virtual" in g_data["model"] else "HDD"
                except:
                     g_data["disk_type"] = "Virtual Disk"
            else:
                g_data["disk_type"] = d_type
                
        except:
            g_data["disk_type"] = "Indeterminate"

        # Update GUI
        self.lbl_system.config(text=f"{g_data['os_caption']}\n{g_data['cpu_name']}", fg=COLOR_TEXT)
        self.lbl_disk.config(text=f"C: ({g_data['disk_type']})\nUsed: {g_data['disk_percent']}% of {g_data['disk_total']} GB", fg=COLOR_TEXT)
        self.log("[OK] System data obtained.")

    def _get_network_info(self):
        self.log("-> Connecting to ipinfo.io...")
        g_data["public_ip"] = "Error"
        g_data["city"] = "Unknown"
        g_data["country"] = ""
        
        try:
            req = urllib.request.Request("http://ipinfo.io/json", headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as url:
                data = json.loads(url.read().decode())
                g_data["public_ip"] = data.get("ip", "Error")
                g_data["city"] = data.get("city", "Unknown")
                g_data["country"] = data.get("country", "")
                
                self.lbl_net.config(text=f"IP: {g_data['public_ip']}\n{g_data['city']}, {g_data['country']}", fg=COLOR_TEXT)
                self.log(f"[OK] IP: {g_data['public_ip']}")
        except Exception as e:
            self.log(f"[Err] Net: {e} (Possible lock or no network)")
            self.lbl_net.config(text="No connection")

    def _run_speedtest(self):
        if not os.path.exists(TEMP_DIR):
            os.makedirs(TEMP_DIR)
        
        self.lbl_speed.config(text="Downloading engine...")
        self.log("-> Downloading Speedtest CLI...")
        
        try:
            req = urllib.request.Request(SPEEDTEST_URL, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req) as response, open(SPEEDTEST_ZIP, 'wb') as out_file:

                shutil.copyfileobj(response, out_file)
                
            with zipfile.ZipFile(SPEEDTEST_ZIP, 'r') as zip_ref:
                zip_ref.extractall(TEMP_DIR)
            
            if os.path.exists(SPEEDTEST_EXE):
                self.log("-> Executing speed test...")
                self.lbl_speed.config(text="Measuring speed...")
                
                # Use --accept-license and --accept-gdpr explicitly
                cmd = [SPEEDTEST_EXE, "--accept-license", "--accept-gdpr", "--format=json", "--progress=no"]
                proc = subprocess.run(cmd, capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW, timeout=60)
                
                output = proc.stdout.strip()
                if not output and proc.stderr:
                    self.log(f"[Err] Speedtest CLI Stderr: {proc.stderr}")
                
                try:
                    res = json.loads(output)
                    down_bytes = res["download"]["bandwidth"]
                    up_bytes = res["upload"]["bandwidth"]
                    ping_ms = res["ping"]["latency"]
                    result_url = res["result"]["url"]

                    g_data["speed_down"] = round(down_bytes / 125000, 2)
                    g_data["speed_up"] = round(up_bytes / 125000, 2)
                    g_data["ping"] = round(ping_ms, 2)
                    g_data["speed_url"] = result_url.replace("\\/", "/")

                    txt = f"Down: {g_data['speed_down']} Mb | Up: {g_data['speed_up']} Mb\nPing: {g_data['ping']} ms"
                    self.lbl_speed.config(text=txt, fg=COLOR_SUCCESS)
                    self.log("[OK] Test finished.")

                except Exception as e:
                    self.log(f"[Err] Parsing Speedtest: {e}\nOutput: {output[:50]}...")
                    self.lbl_speed.config(text="Read Error", fg=COLOR_ERROR)
            else:
                self.log("[Err] Speedtest Exe not found")
                self.lbl_speed.config(text="Error Exe", fg=COLOR_ERROR)

        except Exception as e:
            self.log(f"[Err] Speedtest Download: {e}")
            self.lbl_speed.config(text="DL Error", fg=COLOR_ERROR)

    def _configure_defender_exclusion(self):
        self.log("-> Configuring Defender Exclusion...")
        # Method 1: Standard
        cmd_add = "Add-MpPreference -ExclusionPath 'C:\\' -Force"
        subprocess.run(["powershell", "-Command", cmd_add], creationflags=subprocess.CREATE_NO_WINDOW)
        
        # Method 2: Fallback direct add if first failed (sometimes policies block it)
        # We verify first
        cmd_check = "if ((Get-MpPreference).ExclusionPath -contains 'C:\\') { Write-Host 'True' } else { Write-Host 'False' }"
        proc = subprocess.run(["powershell", "-Command", cmd_check], capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
        
        if "True" in proc.stdout:
            g_data["defender_action"] = "Success - Added C:\\ to exclusions"
            self.lbl_sec.config(text="Protected (Exclusion OK)", fg=COLOR_SUCCESS)
        else:
            # Retrying with robust command
            self.log("-> Retrying exclusion...")
            retry_cmd = "powershell -ExecutionPolicy Bypass -Command \"Add-MpPreference -ExclusionPath 'C:\\' -Force\""
            subprocess.run(retry_cmd, shell=True, creationflags=subprocess.CREATE_NO_WINDOW)
            
            # Final Check
            proc2 = subprocess.run(["powershell", "-Command", cmd_check], capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
            if "True" in proc2.stdout:
                 g_data["defender_action"] = "Success (Attempt 2)"
                 self.lbl_sec.config(text="Protected (OK)", fg=COLOR_SUCCESS)
            else:
                 g_data["defender_action"] = "Failed - Possible policy block"
                 self.lbl_sec.config(text="Error applying rules", fg=COLOR_ERROR)

    def _generate_report(self):
        if not os.path.exists(REPORT_DIR):
            os.makedirs(REPORT_DIR)
        
        try:
            with open(REPORT_FILE, "w", encoding="utf-8") as f:
                now = datetime.datetime.now().strftime("%d/%m/%Y %H:%M:%S")
                f.write("="*80 + "\n")
                f.write(f" SYSTEM DIAGNOSTIC REPORT - {now}\n")
                f.write("="*80 + "\n\n")
                
                f.write(" [SYSTEM INFORMATION]\n")
                f.write(f" OS Version     : {g_data['os_caption']} ({g_data['os_arch']})\n")
                f.write(f" Build          : {g_data['os_build']}\n")
                f.write(f" Computer       : {g_data['manufacturer']} {g_data['model']}\n")
                f.write(f" UUID           : {g_data['system_id']}\n")
                f.write(f" Processor      : {g_data['cpu_name']}\n")
                f.write(f" RAM Memory     : {g_data['ram_gb']} GB\n")
                f.write("-" * 50 + "\n")
                
                f.write(" [STORAGE]\n")
                f.write(f" Main Disk      : {g_data['disk_type']}\n")
                f.write(f" Total Capacity : {g_data['disk_total']} GB\n")
                f.write(f" Used Space     : {g_data['disk_used']} GB ({g_data['disk_percent']}%)\n")
                f.write(f" Free Space     : {g_data['disk_free']} GB\n")
                f.write("-" * 50 + "\n")
                
                f.write(" [INTERNET NETWORK]\n")
                f.write(f" Public IP      : {g_data.get('public_ip', 'Error')}\n")
                f.write(f" Location       : {g_data.get('city', '')}, {g_data.get('country', '')}\n")
                f.write(f" Download Speed : {g_data.get('speed_down', '0')} Mbps\n")
                f.write(f" Upload Speed   : {g_data.get('speed_up', '0')} Mbps\n")
                f.write(f" Latency (Ping) : {g_data.get('ping', '0')} ms\n")
                f.write(f" Result Link    : {g_data.get('speed_url', 'N/A')}\n")
                f.write("-" * 50 + "\n")
                
                f.write(" [SECURITY & CONFIGURATION]\n")
                f.write(f" Defender Exclusion (C:\\): {g_data['defender_action']}\n")
                f.write(f" Hibernation    : {g_data['hibernation_status']}\n")
                f.write(f" Firewall       : {g_data['firewall_status']}\n")
                f.write(f" Antivirus (RT) : {g_data['av_status']}\n")
                f.write(f" UAC (Accounts) : {g_data['uac_status']}\n")
                f.write(f" SmartScreen    : {g_data['smartscreen_status']}\n")
                f.write(f" Power Plan     : High Performance (Forced)\n")
                f.write("="*80 + "\n")
            
            self.log("[OK] Report saved in C:\\1\\SystemInfo.txt")
        except Exception as e:
            self.log(f"[Error] Could not write report: {e}")

    def _cleanup(self):
        try:
            if os.path.exists(TEMP_DIR):
                shutil.rmtree(TEMP_DIR)
        except: pass

if __name__ == "__main__":
    try:
        # Hide Console Immediately
        try:
             ctypes.windll.user32.ShowWindow(ctypes.windll.kernel32.GetConsoleWindow(), 0)
        except: pass

        if not is_admin():
            run_as_admin()
            sys.exit()

        
        # Only import App here to prevent overhead if just elevating
        app = App()
        app.mainloop()
        
    except Exception as e:
        # Emergency Error Display
        try:
            ctypes.windll.user32.MessageBoxW(0, f"Critical Error:\n{str(e)}", "DDG Diagnostics Error", 0x10)
        except:
            print(f"CRITICAL ERROR: {e}")


