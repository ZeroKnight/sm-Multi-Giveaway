/*
 * Copyright (c) 2016 Alex "ZeroKnight" George
 *
 * This file is licensed under the MIT License. For details, please see the
 * LICENSE file that should be included with the source code, or
 * <https://opensource.org/licenses/MIT>
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

const char[] PLUGIN_NAME    = "Multi-Giveaway";
const char[] PLUGIN_AUTHOR  = "Alex \"ZeroKnight\" George";
const char[] PLUGIN_DESC    = "Expansive Giveaway system with numerous types of Giveaway events and stats";
const char[] PLUGIN_VERSION = "0.1.0";
const char[] PLUGIN_URL     = "http:/github.com/ZeroKnight/sm-Multi-Giveaway";
const char[] PLUGIN_TAG     = "[MG]";

public Plugin myinfo =
{
  name        = PLUGIN_NAME,
  author      = PLUGIN_AUTHOR,
  description = PLUGIN_DESC,
  version     = PLUGIN_VERSION,
  url         = PLUGIN_URL
};

enum MG_GiveawayType { MG_Dice = 1, MG_Number = 2, MG_Kill = 4, MG_All = 7 };

// TODO: Put things like this in a personal core library?
#define CVAR(%1) ConVar cv_%1;
const char[] CVAR_PREFIX = "multi_giveaway";
CVAR("version");
CVAR("flags");
CVAR("enaled_types");
CVAR("player_state");
CVAR("min_conn_time");
CVAR("dice_min");
CVAR("dice_max");
CVAR("dice_show_rolls");
CVAR("dice_rerolls");
CVAR("number_min");
CVAR("number_max");
CVAR("number_show_guesses");

void RegisterConVars()
{
  // XXX: Why is CreateConVar() not overloaded?! Are there even overloads?!
  const char[32] sMG_All; IntToString(MG_All, sMG_All, sizeof(sMG_All));

  cv_version = CreateConVar(
    "multi_givaway_version",
    PLUGIN_VERSION,
    "Plugin version",
    FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
  cv_flags = CreateConVar(
    "multi_givaway_flags",
    "b",
    "List of admin flags allowed to manage giveaways");
  cv_enabled_types = CreateConVar(
    "multi_giveaway_enabled_types",
    sMG_All,
    "Bit-field (sum of options) of enabled Giveaway types",
    true, 1.0,
    true, MG_All);
  cv_player_state = CreateConVar(
    "multi_giveaway_player_state",
    "7",
    "Bit-field (sum of options) of player states that are valid for giveaway participation: 1 - Spectator, 2 - Dead, 4 - Alive"
    true, 1.0,
    true, 7.0);
  cv_min_conn_time = CreateConVar( // TODO: Allow certain giveaways to override (eg. kill objective)
    "multi_giveaway_min_conn_time",
    "300", // 5 minutes
    "Amount of time in seconds a player must be connected to participate in a giveaway",
    true, 0.0);

  cv_dice_min = CreateConVar(
    "multi_giveaway_dice_min",
    "1",
    "Lowest possible number a player may roll",
    true, 1.0);
  cv_dice_max = CreateConVar(
    "multi_giveaway_dice_max",
    "50",
    "Highest possible number a player may roll");
  cv_dice_show_rolls = CreateConVar(
    "multi_giveaway_dice_show_rolls",
    "0",
    "Who can see other clients' dice rolls: 0 - Nobody, 1 - Admins, 2 - Everyone",
    true, 0.0
    true, 2.0);
  cv_dice_rerolls = CreateConVar(
    "multi_giveaway_dice_reroll",
    "0",
    "Number of 'do-overs' a player gets when rolling. Only the last is counted, for better or for worse");

  cv_number_min = CreateConVar(
    "multi_giveaway_number_min",
    "1",
    "Lower bound of the range of numbers",
    true, 1.0);
  cv_number_max = CreateConVar(
    "multi_giveaway_number_max",
    "100",
    "Upper bound of the range of numbers");
  cv_number_show_guesses = CreateConVar(
    "multi_giveaway_number_show_guesses",
    "2",
    "Who can see other clients' guesses: 0 - Nobody, 1 - Admins, 2 - Everyone",
    true, 0.0,
    true, 2.0);
}

void RegisterCommands()
{
  // XXX: Is there a better way to create aliases?
  // RegConsoleCmd for client commands (ie participation)
  // RegAdminCmd for admin commands (ie (start|stop)ing giveaways
  // methodmap may be helpful

  RegAdminCmd("sm_mg_reload", Command_ReloadConfig, ADMFLAG_CONFIG,
    "Reload configuration file");
  // start/stop/status <type> - style command
  RegAdminCmd("sm_multigiveaway", Command_MultiGiveaway, ADMFLAG_GENERIC,
    "Manage giveaways");
  RegAdminCmd("sm_mg", Command_MultiGiveaway, ADMFLAG_GENERIC,
    "Manage giveaways");
}

void LoadConfig()
{
  // ...
}

// Forwards  ///////////////////////

public void OnPluginStart()
{
  // NOTE:
  // load our config. make use of the Kv*/KeyValue functions
  // for flag cvars, ReadFlagString(), GetUserFlagBits() and & are our friends
  // register event forwards (CreateGlobalForward())? ie kill-objectives

  RegisterCommands();
  RegisterConVars();

  const char[128] translatefile;
  Format(translatefile, sizeof(translatefile), "%s.phrases", PLUGIN_NAME);
  LoadTranslations(translatefile);

  return Plugin_Handled;
}

public void OnClientDisconnect(int client)
{
  // remove client from any current lists, etc
}

// Callbacks ///////////////////////

public Action Command_ReloadConfig(int client, int args)
{
  LoadConfig();
  LogAction(client, -1, "%s configuration reloaded by %L", PLUGIN_NAME, client);
  ReplyToCommand(client, "%s Configuration reloaded!", PLUGIN_TAG);
  return Plugin_Handled;
}

public Action Command_MultiGiveaway(int client, int args)
{
  // sm_mg <start|stop|restart> <dice|number|kill|...> [params]...
  char[32] action, type;

  GetCmdArgString(1, action, sizeof(action));
  GetCmdArgString(2, type, sizeof(type));

  // ...
}

// vim: et sts=2 sw=2

