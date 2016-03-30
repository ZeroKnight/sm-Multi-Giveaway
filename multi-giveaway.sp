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

char PLUGIN_NAME[]    = "Multi-Giveaway";
char PLUGIN_AUTHOR[]  = "Alex \"ZeroKnight\" George";
char PLUGIN_DESC[]    = "Expansive Giveaway system with numerous types of Giveaway events and stats";
char PLUGIN_VERSION[] = "0.1.0";
char PLUGIN_URL[]     = "http:/github.com/ZeroKnight/sm-Multi-Giveaway";
char PLUGIN_TAG[]     = "[MG]";

public Plugin myinfo =
{
  name        = PLUGIN_NAME,
  author      = PLUGIN_AUTHOR,
  description = PLUGIN_DESC,
  version     = PLUGIN_VERSION,
  url         = PLUGIN_URL
};

/* NOTE: (<<= 1) is actually a neat thing that SourcePawn does. It lets you
 * specify how to 'increment' each enumeration. In this case, each one will be
 * the previous value left shifted 1, which gives us our bit-field.
 */
enum GiveawayType (<<= 1)
{
  GT_Invalid = -1, GT_Dice = 1, GT_Number, GT_Kill, GT_All = 7
}

//File configfile = ...

// TODO: Put things like this in a personal core library?
#define CVAR(%1) ConVar cv_%1
char CVAR_PREFIX[] = "multi_giveaway";
CVAR(version);
CVAR(flags);
CVAR(enabled_types);
CVAR(player_state);
CVAR(min_conn_time);
CVAR(dice_min);
CVAR(dice_max);
CVAR(dice_show_rolls);
CVAR(dice_rerolls);
CVAR(number_min);
CVAR(number_max);
CVAR(number_show_guesses);

void RegisterConVars()
{
  // XXX: Function overloads would be nice. Or casting that worked on strings.
  char sGT_All[32]; IntToString(GT_All, sGT_All, sizeof(sGT_All));

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
    sGT_All,
    "Bit-field (sum of options) of enabled Giveaway types",
    FCVAR_NONE,
    true, 1.0,
    true, float(GT_All));
  cv_player_state = CreateConVar(
    "multi_giveaway_player_state",
    "7",
    "Bit-field (sum of options) of player states that are valid for giveaway participation: 1 - Spectator, 2 - Dead, 4 - Alive",
    FCVAR_NONE,
    true, 1.0,
    true, 7.0);
  cv_min_conn_time = CreateConVar( // TODO: Allow certain giveaways to override (eg. kill objective)
    "multi_giveaway_min_conn_time",
    "300", // 5 minutes
    "Amount of time in seconds a player must be connected to participate in a giveaway",
    FCVAR_NONE,
    true, 0.0);

  cv_dice_min = CreateConVar(
    "multi_giveaway_dice_min",
    "1",
    "Lowest possible number a player may roll",
    FCVAR_NONE,
    true, 1.0);
  cv_dice_max = CreateConVar(
    "multi_giveaway_dice_max",
    "50",
    "Highest possible number a player may roll");
  cv_dice_show_rolls = CreateConVar(
    "multi_giveaway_dice_show_rolls",
    "0",
    "Who can see other clients' dice rolls: 0 - Nobody, 1 - Admins, 2 - Everyone",
    FCVAR_NONE,
    true, 0.0,
    true, 2.0);
  cv_dice_rerolls = CreateConVar(
    "multi_giveaway_dice_reroll",
    "0",
    "Number of 'do-overs' a player gets when rolling. Only the last is counted, for better or for worse");

  cv_number_min = CreateConVar(
    "multi_giveaway_number_min",
    "1",
    "Lower bound of the range of numbers",
    FCVAR_NONE,
    true, 1.0);
  cv_number_max = CreateConVar(
    "multi_giveaway_number_max",
    "100",
    "Upper bound of the range of numbers");
  cv_number_show_guesses = CreateConVar(
    "multi_giveaway_number_show_guesses",
    "2",
    "Who can see other clients' guesses: 0 - Nobody, 1 - Admins, 2 - Everyone",
    FCVAR_NONE,
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

void GetTypeName(const GiveawayType type, char[] str, int sz)
{
  switch (type)
  {
    case GT_Invalid: return;
    case GT_Dice:    StrCopy(str, sz, "Dice");
    case GT_Number:  StrCopy(str, sz, "Number");
    case GT_Kill:    StrCopy(str, sz, "Kill");
    default:         return;
  }
}

GiveawayType GetType(const char[] typename)
{
  if      (StrEqual(typename, "dice", false))   return GT_Dice;
  else if (StrEqual(typename, "number", false)) return GT_Number;
  else if (StrEqual(typename, "kill", false))   return GT_Kill;
  else return GT_Invalid;
}

bool LoadConfig()
{
  //if (configfile != null) // is this boilerplate necessary?
    //CloseHandle(configfile);
  // ...
  return true;
}

// TODO: Return something meaningful if possible, rather than void
void Giveaway_Start(const GiveawayType type, const ArrayList args, int client)
{
  char typename[32];
  GetTypeName(type, typename, sizeof(typename));
  ReplyToCommand(client, "%s Starting Giveaway '%s'", PLUGIN_TAG, typename);
  // ...
}

void Giveaway_Stop(const GiveawayType type, int client)
{
  char typename[32];
  GetTypeName(type, typename, sizeof(typename));
  ReplyToCommand(client, "%s Stopping Giveaway '%s'", PLUGIN_TAG, typename);
  // ...
}

void Giveaway_Restart(const GiveawayType type, int client)
{
  char typename[32];
  GetTypeName(type, typename, sizeof(typename));
  ReplyToCommand(client, "%s Restarting Giveaway '%s'", PLUGIN_TAG, typename);
  // ...
}

void Giveaway_Status()
{
  // return what giveaway is running, if any
  // do other things
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

  char translatefile[128];
  Format(translatefile, sizeof(translatefile), "%s.phrases", PLUGIN_NAME);
  //LoadTranslations(translatefile);
}

public void OnClientDisconnect(int client)
{
  // remove client from any current lists, etc
}

// Callbacks ///////////////////////

public Action Command_ReloadConfig(int client, int args)
{
  bool success = LoadConfig();
  LogAction(client, -1, "%s configuration reload by %L", PLUGIN_NAME, client);
  if (success)
    ReplyToCommand(client, "%s Configuration reloaded!", PLUGIN_TAG);
  else // TODO: Provide error information, etc
    ReplyToCommand(client, "%s Configuration error!", PLUGIN_TAG);

  return Plugin_Handled;
}

public Action Command_MultiGiveaway(int client, int args)
{
  // sm_mg [start|stop|restart|status] <dice|number|kill|...> [params]...

  if (!args)
  {
    // Interactive Mode: Menu-based interface
    ReplyToCommand(client, "%s Interactive mode not yet implemented!",
                   PLUGIN_TAG);
    return Plugin_Handled;
  }

  char action[32], typename[32];

  GetCmdArg(1, action, sizeof(action));
  GetCmdArg(2, typename, sizeof(typename));
  GiveawayType type = GetType(typename);

  if (StrEqual(action, "start", false))
  {
    ArrayList typeargs = CreateArray();
    for (int i = 3; i <= GetCmdArgs(); ++i)
    {
      char arg[64];
      GetCmdArg(i, arg, sizeof(arg));
      typeargs.PushString(arg);
    }
    Giveaway_Start(type, typeargs, client);
  }
  else if (StrEqual(action, "stop", false))
    Giveaway_Stop(type, client);
  else if (StrEqual(action, "restart", false))
    Giveaway_Restart(type, client);
  else if (StrEqual(action, "status", false))
    Giveaway_Status();
  else
  {
    // TODO: List valid actions in error message, or inform of a help command
    ReplyToCommand(client, "%s Invalid action '%s'", PLUGIN_TAG, action);
    return Plugin_Handled;
  }

  return Plugin_Handled;
}

// vim: et sts=2 sw=2

