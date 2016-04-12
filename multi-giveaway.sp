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

const int TYPEOPT_MAX_LEN = 64;

/* NOTE: (<<= 1) is actually a neat thing that SourcePawn does. It lets you
 * specify how to 'increment' each enumeration. In this case, each one will be
 * the previous value left shifted 1, which gives us our bit-field.
 */
enum GiveawayType (<<= 1)
{
  GT_Invalid = -1, GT_Dice = 1, GT_Number, GT_Kill, GT_All = 7
};
const int nGTypes = 3;

// Global state variables/data structures
StringMap GiveawayData;
ArrayList Dice_PlayerRolls;
ArrayList Dice_BestRolls;
ArrayList Dice_ReRolls;
ArrayList Number_PlayerGuesses;

ArrayList Current_TypeOpts; // NOTE: Subject to change

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
  // NOTE: Use HookConVarChange() for anything that needs it

  // XXX: Function overloads would be nice. Or casting that worked on strings.
  char sGT_All[32]; IntToString(view_as<int>(GT_All), sGT_All, sizeof(sGT_All));

  // Core
  cv_version = CreateConVar(
    "multi_giveaway_version",
    PLUGIN_VERSION,
    "Plugin version",
    FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
  cv_flags = CreateConVar(
    "multi_giveaway_flags",
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

  // Dice
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
    "multi_giveaway_dice_rerolls",
    "0",
    "Number of 'do-overs' a player gets when rolling. Only the last is counted, for better or for worse",
    FCVAR_NONE,
    true, 0.0);

  // Number Guess
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
  // RegAdminCmd for admin commands (ie (start|stop)ing giveaways methodmap may
  // be helpful
  //
  // We can use AddCommandListener() to allow for "commands" that aren't
  // actually registered commands (think 'nominate')

  RegAdminCmd("sm_mg_reload", Command_ReloadConfig, ADMFLAG_CONFIG,
    "Reload configuration file");
  RegAdminCmd("sm_multigiveaway", Command_MultiGiveaway, ADMFLAG_GENERIC,
    "Manage giveaways");
  RegAdminCmd("sm_mg", Command_MultiGiveaway, ADMFLAG_GENERIC,
    "Manage giveaways");
  RegAdminCmd("sm_dice_rig", Command_Dice_Rig, ADMFLAG_CHEATS,
              "Rigs the Dice Giveaway so the chosen client wins");

  RegConsoleCmd("sm_rolldice", Command_Dice_Roll,
                "Rolls the dice during a Dice Giveaway");
  RegConsoleCmd("sm_reroll", Command_Dice_ReRoll,
                "Rolls the dice again during a Giveaway, giving you a new result (for better or worse!");
}

bool LoadConfig()
{
  //if (configfile != null) // is this boilerplate necessary?
    //CloseHandle(configfile);
  // ...
  return true;
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

void GetTypeOpts(char[] str, const int sz)
{
  char opt[64];
  for (int i = 0; i < Current_TypeOpts.Length; ++i)
  {
    Current_TypeOpts.GetString(i, opt, sizeof(opt));
    StrCat(str, sz, opt);
    StrCat(str, sz, "; ");
  }
}

void ArraySetAll(ArrayList& array, any value)
{
  for (int i = 0; i < array.Length; ++i)
    array.Set(i, value);
}

void SendToAdmins(const char[] str)
{
  for (int i = 1; i <= MaxClients; ++i)
  {
    if (IsClientInGame(i) && GetUserAdmin(i) != INVALID_ADMIN_ID)
      PrintToChat(i, "%s", str);
  }
}

bool Giveaway_Start(const GiveawayType type,
                    const ArrayList opts,
                    const int client,
                    const bool restarting=false)
{
  GiveawayType cg; GiveawayData.GetValue("Current", cg);
  char typename_current[32];
  GetTypeName(cg, typename_current, sizeof(typename_current));
  if (cg != GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Giveaway_In_Progress",
                   typename_current);
    return false;
  }

  char typename[32], typeopts[512];
  GetTypeName(type, typename, sizeof(typename));
  GetTypeOpts(typeopts, sizeof(typeopts));
  if (type == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Invalid_Type", typename);
    return false;
  }
  else if (type != GT_Dice) // XXX: Temporary
  {
    ReplyToCommand(client, "%s Not yet implemented!", PLUGIN_TAG);
    return false;
  }

  GiveawayData.SetValue("Current", type);
  GiveawayData.SetValue("Participants", 0);
  GiveawayData.SetValue("Starter", client);

  if (!restarting)
  {
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Start", typename);
    LogAction(client, -1, "%L started Giveaway \"%s\" with options: %s",
              client, typename, typeopts);
  }
  switch (type)
  {
    case GT_Dice:
    {
      // TODO: Allow changing of "roll" command
      PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_Start", "rolldice");
      if (cv_dice_rerolls.IntValue)
        PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_ReRoll", "reroll");
    }
    case GT_Number:
    {
      PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Number_Start", "guess",
                     cv_number_min.IntValue, cv_number_max.IntValue);
    }
    case GT_Kill:
    {
    }
  }
  return true;
}

void Giveaway_Stop(const int client, const bool restarting=false)
{
  GiveawayType cg; GiveawayData.GetValue("Current", cg);
  if (cg == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway");
    return;
  }

  char typename[32];
  GetTypeName(cg, typename, sizeof(typename));
  if (!restarting)
  {
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Stop", typename);
    LogAction(client, -1, "%L stopped Giveaway \"%s\"", client, typename);
  }
  switch (cg)
  {
    case GT_Dice:
    {
      if (!restarting)
      {
        if (Dice_BestRolls.Length)
        {
          int best = Dice_GetBestRoll();
          int nbest = Dice_BestRolls.Length;
          int rigged; GiveawayData.GetValue("Dice_RiggedPlayer", rigged);
          int winner;
          char name[MAX_NAME_LENGTH];
          if (nbest > 1)
          {
            PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_Tie");
            winner = Dice_BestRolls.Get(GetRandomInt(0, nbest-1));
          }
          else winner = Dice_BestRolls.Get(0);

          // Rig the Giveaway
          if (rigged != -1) winner = rigged;

          GetClientName(winner, name, sizeof(name));
          PrintToChatAll("%s %t", PLUGIN_TAG,
                         best == cv_dice_max.IntValue ?
                          "MG_Dice_Win_Perfect" : "MG_Dice_Win", name, best);
        }
        else
          PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Giveaway_Cancelled",
                         typename);
      }
      GiveawayData.SetValue("Dice_RiggedPlayer", -1);
      ArraySetAll(Dice_PlayerRolls, 0);
      ArraySetAll(Dice_ReRolls, cv_dice_rerolls.IntValue);
      Dice_BestRolls.Clear();
    }
    case GT_Number:
    {
      ArraySetAll(Number_PlayerGuesses, -1);
    }
    case GT_Kill:
    {
    }
  }
  GiveawayData.SetValue("Current", GT_Invalid);
  GiveawayData.SetValue("Participants", -1);
  GiveawayData.SetValue("Starter", -1);
  Current_TypeOpts.Clear();
}

void Giveaway_Restart(const int client)
{
  GiveawayType cg; GiveawayData.GetValue("Current", cg);
  if (cg == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway");
    return;
  }

  char typename[32], typeopts[512];
  GetTypeName(cg, typename, sizeof(typename));
  GetTypeOpts(typeopts, sizeof(typeopts));

  ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Restart", typename);
  LogAction(client, -1, "%L restarted Giveaway \"%s\" with options: %s",
            client, typename, typeopts);
  Giveaway_Stop(client, true);
  Giveaway_Start(cg, Current_TypeOpts, client, true);
}

void Giveaway_Status(const int client)
{
  GiveawayType cg; GiveawayData.GetValue("Current", cg);
  if (cg == GT_Invalid)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway");
    return;
  }

  char typename[32], typeopts[512];
  GetTypeName(cg, typename, sizeof(typename));
  GetTypeOpts(typeopts, sizeof(typeopts));

  ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Status", typename, typeopts);
  // do other things
}

void Dice_Roll(const int client, const bool rerolling=false)
{
  if (!rerolling && Dice_PlayerRolls.Get(client))
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_Rolled");
    if (cv_dice_rerolls.IntValue)
    {
      if (Dice_ReRolls.Get(client))
        ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll", "reroll");
      else
        ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_None");
    }
    return;
  }

  int rand = GetRandomInt(cv_dice_min.IntValue, cv_dice_max.IntValue);
  int best = Dice_GetBestRoll();
  int p; GiveawayData.GetValue("Participants", p);
  int rigged; GiveawayData.GetValue("Dice_RiggedPlayer", rigged);

  if (!rerolling) GiveawayData.SetValue("Participants", ++p);

  // Make the rig look convincing
  if (rigged != -1 && client == rigged) rand = cv_dice_max.IntValue;

  Dice_PlayerRolls.Set(client, rand);
  if (rand > best)
  {
    Dice_BestRolls.Clear();
    Dice_BestRolls.Push(client);
  }
  else if (rand == best && Dice_BestRolls.FindValue(client) == -1)
    Dice_BestRolls.Push(client);

  char name[MAX_NAME_LENGTH];
  GetClientName(client, name, sizeof(name));
  switch (cv_dice_show_rolls.IntValue)
  {
    case 0:
    {
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_Result", "You",
                     rand);
    }
    case 1:
    {
      char str[128];
      Format(str, sizeof(str), "%s %T", PLUGIN_TAG, "MG_Dice_Result",
             LANG_SERVER, name, rand);
      SendToAdmins(str);
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_Result", name, rand);
    }
    case 2:
    {
      PrintToChatAll("%s %t", PLUGIN_TAG, "MG_Dice_Result", name, rand);
    }
  }
}

int Dice_GetBestRoll()
{
  int best = -1;
  for (int i = 0; i < Dice_PlayerRolls.Length; ++i)
  {
    int roll = Dice_PlayerRolls.Get(i);
    if (roll > best) best = roll;
  }

  return best;
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

  char translatefile[64];
  Format(translatefile, sizeof(translatefile), "%s.phrases", PLUGIN_NAME);
  LoadTranslations(translatefile);
}

public void OnMapStart()
{
  /* Initialize global state and data structures */
  GiveawayData         = new StringMap();
  Current_TypeOpts     = new ArrayList(TYPEOPT_MAX_LEN);
  Dice_PlayerRolls     = new ArrayList(1, MAXPLAYERS);
  Dice_BestRolls       = new ArrayList(1);
  Dice_ReRolls         = new ArrayList(1, MAXPLAYERS);
  Number_PlayerGuesses = new ArrayList(1, MAXPLAYERS);

  GiveawayData.SetValue("Current", GT_Invalid);
  GiveawayData.SetValue("Participants", -1);
  GiveawayData.SetValue("Starter", -1);

  // Dice
  GiveawayData.SetValue("Dice_RiggedPlayer", -1);
  ArraySetAll(Dice_PlayerRolls, 0);
  // FIXME: Hook into convar change and re-set this array
  ArraySetAll(Dice_ReRolls, cv_dice_rerolls.IntValue);

  // Number Guess
  GiveawayData.SetValue("Number_ClosestGuess", -1);
  // TODO: replace with a getbest function like dice; perhaps even a unique one?
  // eg GetLargestElement?
}

public void OnClientDisconnect(int client)
{
  int p; GiveawayData.GetValue("Participants", p);
  int s; GiveawayData.GetValue("Starter", s);
  GiveawayData.SetValue("Participants", p-1);
  if (s == client) GiveawayData.SetValue("Starter", -1);

  // Dice
  int best = Dice_GetBestRoll();
  if (Dice_PlayerRolls.Length && best == Dice_PlayerRolls.Get(client))
  {
    for (int i = 0; i < Dice_PlayerRolls.Length; ++i)
    {
      if (Dice_BestRolls.Get(i) == client) continue;
      best = Dice_PlayerRolls.Get(i);
      break;
    }
  }
  Dice_PlayerRolls.Set(client, 0);
  Dice_BestRolls.Erase(client);
  GiveawayData.SetValue("Dice_RiggedPlayer", -1);

  // Number Guess
  Number_PlayerGuesses.Set(client, -1);
}

// Callbacks ///////////////////////

public Action Command_ReloadConfig(int client, int args)
{
  bool success = LoadConfig();
  LogAction(client, -1, "%s configuration reload by %L", PLUGIN_NAME, client);
  if (success)
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Config_Reloaded");
  else // TODO: Provide error information, etc
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Config_Error");

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
    if (args < 2)
    {
      /* No type specified, inform client of valid types */
      char typenames[32*nGTypes];
      for (int i = 0; i < nGTypes; ++i)
      {
        char name[32];
        GetTypeName(view_as<GiveawayType>(1<<i), name, sizeof(name));
        StrCat(typenames, sizeof(typenames), name);
        StrCat(typenames, sizeof(typenames), ", ");
      }
      ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Type_Needed", typenames);
      return Plugin_Handled;
    }

    for (int i = 3; i <= GetCmdArgs(); ++i)
    {
      char opt[TYPEOPT_MAX_LEN];
      GetCmdArg(i, opt, sizeof(opt));
      Current_TypeOpts.PushString(opt);
    }
    Giveaway_Start(type, Current_TypeOpts, client);
  }
  else if (StrEqual(action, "stop", false))
    Giveaway_Stop(client);
  else if (StrEqual(action, "restart", false))
    Giveaway_Restart(client);
  else if (StrEqual(action, "status", false))
    Giveaway_Status(client);
  else
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Invalid_Action", action,
                   "start, stop, restart, status");
  }

  return Plugin_Handled;
}

public Action Command_Dice_Roll(int client, int args)
{
  GiveawayType cg; GiveawayData.GetValue("Current", cg);
  if (cg != GT_Dice)
  {
    char typename[32];
    GetTypeName(GT_Dice, typename, sizeof(typename));
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway_Type",
                   typename);
    return Plugin_Handled;
  }

  Dice_Roll(client);

  return Plugin_Handled;
}

public Action Command_Dice_ReRoll(int client, int args)
{
  int rerolls = cv_dice_rerolls.IntValue;
  if (!rerolls)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_Disabled");
    return Plugin_Handled;
  }
  if (!Dice_PlayerRolls.Get(client))
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_Roll_Needed");
    return Plugin_Handled;
  }

  int rolls_left = Dice_ReRolls.Get(client);
  if (rolls_left)
  {
    int last_roll = Dice_PlayerRolls.Get(client);
    Dice_Roll(client, true);
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRolled", last_roll,
                   --rolls_left);
    Dice_ReRolls.Set(client, rolls_left);
  }
  else
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Dice_ReRoll_None");

  return Plugin_Handled;
}

public Action Command_Dice_Rig(int client, int args)
{
  GiveawayType cg; GiveawayData.GetValue("Current", cg);
  if (cg != GT_Dice)
  {
    char typename[32];
    GetTypeName(GT_Dice, typename, sizeof(typename));
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_No_Giveaway_Type",
                   typename);
    return Plugin_Handled;
  }
  if (args < 1)
  {
    ReplyToCommand(client, "%s %t", PLUGIN_TAG, "MG_Target_Required");
    return Plugin_Handled;
  }

  char arg[MAX_NAME_LENGTH], target_name[MAX_NAME_LENGTH];
  int target[1];
  bool tnml;
  GetCmdArg(1, arg, sizeof(arg));
  int rv = ProcessTargetString(arg, client, target, 1, COMMAND_FILTER_CONNECTED,
                               target_name, sizeof(target_name), tnml);
  if (rv)
  {
    ShowActivity2(client, PLUGIN_TAG, " %t", "MG_Dice_Rigged", target_name);
    GiveawayData.SetValue("Dice_RiggedPlayer", target[0]);
  }
  else ReplyToTargetError(client, rv);

  return Plugin_Handled;
}

// vim: et sts=2 sw=2

