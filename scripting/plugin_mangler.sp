/**
 * [ANY] Plugin Mangler
 * 
 * Allows server administrators to manage plugins in batches, as well as move plugins to / from
 * the disabled directory.
 */
#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required
#include <stocksoup/plugin_utils>
#include <stocksoup/log_server>

#define PLUGIN_VERSION "1.2.0"
public Plugin myinfo = {
	name = "[ANY] Plugin Mangler",
	author = "nosoop",
	description = "Load, unload, reload, enable, and disable multiple plugins in one go.",
	version = PLUGIN_VERSION,
	url = "https://github.com/nosoop/SM-PluginMangler"
}

enum PluginAction {
	Action_Invalid = 0,
	Action_Load,
	Action_Reload,
	Action_Unload,
	Action_Enable,
	Action_Disable,
	Action_Find,
	Action_Info,
	Action_RefreshStale
};

char g_ActionCommands[][] = {
	"", "load", "reload", "unload", "enable", "disable", "find", "info", "refresh_stale"
};

char g_ActionInfo[][] = {
	"",
	"Load a plugin",
	"Reloads a plugin",
	"Unload a plugin",
	"Moves a plugin out of 'disabled/' and loads it",
	"Unloads a plugin and moves it to 'disabled/'",
	"Finds plugins matching the regular expression (TODO)",
	"Information about a plugin",
	"Reloads recently installed plugins"
};

int g_LastRefresh;

StringMap g_FuturePluginTimes;

public void OnPluginStart() {
	// EnableDisable.smx conflicts with this plugin's `plugins` server command
	if (DisablePluginFile("EnableDisable")) {
		LogServer("EnableDisable conflicts with this plugin's commands. "
				... "It has been unloaded and moved to the 'disabled/' directory.");
	}
	
	RegAdminCmd("sm_plugins", AdminCmd_PluginManage, ADMFLAG_ROOT);
	
	RegServerCmd("plugins", ServerCmd_PluginManage);
	
	g_FuturePluginTimes = new StringMap();
}

public void OnMapStart() {
	g_LastRefresh = GetTime();
	
	/**
	 * Store times of plugins with mtimes newer than system clock.
	 * 
	 * Keeping track of this means that plugins with mtime newer than clock only get reloaded
	 * when their mtime changes.
	 */
	
	// We can't remove individual items from the StringMap, so we'll have to rebuild it.
	g_FuturePluginTimes.Clear();
	
	Handle iterator = GetPluginIterator();
	while (MorePlugins(iterator)) {
		Handle plugin = ReadPlugin(iterator);
		
		char pluginName[PLATFORM_MAX_PATH], pluginPath[PLATFORM_MAX_PATH];
		
		GetPluginFilename(plugin, pluginName, sizeof(pluginName));
		BuildPath(Path_SM, pluginPath, sizeof(pluginPath), "plugins/%s", pluginName);
		
		int mtime = GetFileTime(pluginPath, FileTime_LastChange);
		
		if (mtime > g_LastRefresh) {
			g_FuturePluginTimes.SetValue(pluginName, mtime, false);
		}
	}
	delete iterator;
}

public Action AdminCmd_PluginManage(int client, int argc) {
	PluginAction action = Action_Invalid;
	if (argc > 0) {
		char actionName[16];
		GetCmdArg(1, actionName, sizeof(actionName));
		
		for (int i = 0; i < view_as<int>(PluginAction); i++) {
			if (strlen(actionName) > 0 && StrEqual(actionName, g_ActionCommands[i])) {
				action = view_as<PluginAction>(i);
			}
		}
		
		if (action == Action_Invalid) {
			ReplyToCommand(client, "[SM] Unknown plugin management command '%s'", actionName);
		}
	} else {
		char command[64];
		GetCmdArg(0, command, sizeof(command));
		
		if (client && GetCmdReplySource() == SM_REPLY_TO_CHAT) {
			ReplyToCommand(client, "[SM] See console output for usage instructions.");
			SetCmdReplySource(SM_REPLY_TO_CONSOLE);
		}
		
		ReplyToCommand(client, "Usage: %s [action] [plugin, ...]", command);
		
		for (int i = 1; i < view_as<int>(PluginAction); i++) {
			ReplyToCommand(client, "    %-16s - %s", g_ActionCommands[i], g_ActionInfo[i]);
		}
	}
	
	bool bSinglePluginAction;
	
	// Perform actions that do not need plugin names passed in.
	switch (action) {
		case Action_RefreshStale: {
			int nReloads;
			bool selfStale;
			char pluginSelfName[PLATFORM_MAX_PATH];
			GetPluginFilename(INVALID_HANDLE, pluginSelfName, sizeof(pluginSelfName));
			
			Handle iterator = GetPluginIterator();
			while (MorePlugins(iterator)) {
				Handle plugin = ReadPlugin(iterator);
				
				char pluginName[PLATFORM_MAX_PATH];
				GetPluginFilename(plugin, pluginName, sizeof(pluginName));
				
				int mtime;
				if (IsPluginStale(pluginName, mtime)) {
					if (StrEqual(pluginName, pluginSelfName)) {
						if (!selfStale) {
							nReloads++;
						}
						
						// Should not reload self while processing other plugins
						selfStale = true;
					} else {
						nReloads++;
						ReloadPlugin(plugin);
					}
					
					// Plugin is now from the future, store time
					if (mtime > GetTime()) {
						g_FuturePluginTimes.SetValue(pluginName, mtime);
					}
				}
			}
			delete iterator;
			
			// Print the number of plugins reloaded so 0 reloads still provides a response
			ReplyToCommand(client, "[SM] %d stale plugin(s) have been found and reloaded.",
					nReloads);
			
			if (selfStale) {
				ReloadPlugin();
			}
			
			g_LastRefresh = GetTime();
		}
		default: {
			bSinglePluginAction = true;
		}
	}
	
	if (!bSinglePluginAction) {
		// was multi-plugin action that was performed above
		return Plugin_Handled;
	}
	
	// TODO get all plugin filenames and treat them as expressions to be expanded?
	
	char pluginName[PLATFORM_MAX_PATH];
	for (int i = 1; i < argc; i++) {
		// off by one, command name at arg 0
		GetCmdArg(i + 1, pluginName, sizeof(pluginName));
		
		// append .smx if necessary for ReplyToCommand messages
		int ext = FindCharInString(pluginName, '.', true);
		if (ext == -1 || StrContains(pluginName[ext], ".smx", false) != 0) {
			StrCat(pluginName, sizeof(pluginName), ".smx");
		}
		
		switch (action) {
			case Action_Load: {
				if (!LoadPluginFile(pluginName)) {
					ReplyToCommand(client,
							"[SM] Plugin %s failed to load: Unable to open file.", pluginName);
				}
			}
			case Action_Reload: {
				if (!ReloadPluginFile(pluginName)) {
					ReplyToCommand(client, "[SM] Plugin %s is not loaded.", pluginName);
				}
			}
			case Action_Unload: {
				if (!UnloadPluginFile(pluginName)) {
					ReplyToCommand(client, "[SM] Plugin %s is not loaded.", pluginName);
				}
			}
			case Action_Enable: {
				if (EnablePluginFile(pluginName)) {
					ReplyToCommand(client,
							"[SM] Plugin %s has been moved out of the 'disabled/' directory.",
							pluginName);
				} else {
					ReplyToCommand(client,
							"[SM] Plugin %s failed to load: Unable to open file.", pluginName);
				}
			}
			case Action_Disable: {
				if (DisablePluginFile(pluginName)) {
					ReplyToCommand(client,
							"[SM] Plugin %s has been moved to the 'disabled/' directory.",
							pluginName);
				} else {
					ReplyToCommand(client, "[SM] Plugin %s is not loaded.", pluginName);
				}
			}
			case Action_Info: {
				if (!PerformPluginCommand("info", pluginName)) {
					ReplyToCommand(client, "[SM] Plugin %s is not loaded.", pluginName);
				}
			}
			case Action_Find: {
				// TODO treat argument as regex and iterate plugin filenames?
				ReplyToCommand(client,
						"[SM] The 'find' subcommand has not been implemented yet.");
			}
		}
	}
	return Plugin_Handled;
}

public Action ServerCmd_PluginManage(int argc) {
	return AdminCmd_PluginManage(0, argc);
}

bool IsPluginStale(const char[] pluginName, int &mtime) {
	char pluginPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, pluginPath, sizeof(pluginPath), "plugins/%s", pluginName);
	
	mtime = GetFileTime(pluginPath, FileTime_LastChange);
	int existingTime;
	
	if (g_FuturePluginTimes.GetValue(pluginName, existingTime)) {
		// If plugin is from the future, check if newer than last known mtime
		return (mtime > existingTime);
	}
	
	// otherwise just check that it's newer than the last full refresh
	return (mtime > g_LastRefresh);
}
