//+------------------------------------------------------------------+
//|                                                 MixBollinger.mq5 |
//|                                     Copyright 2020,Akimasa Ohara |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Akimasa Ohara"
#property link      ""
#property version   "3.00"

#include <Logging\Logger.mqh>
#include <File\FileOutLog.mqh>
#include <Trade\Trade.mqh>
#include <Others\DST\DST.mqh>
#include <Others\NewBar\NewBar.mqh>
#include <Others\Trade\TradePosition.mqh>

// 開発メモ : 1分足起動が前提、銘柄1つにつき1ポジションのみ、起動時にポジションがある場合はEAで起動されたものであれば保存そうでなければエラー、テスター用
//---input変数（共通変数）-----------------------------------------------
input ulong          MagicNumber = 123456789;   // マジックナンバー
input bool           IsUK        = false;       // サマータイム判定時に利用(初期値oanda)
 // alpari : ヨーロッパ
 // oanda : アメリカ（予想）
enum LOGLEVEL{
   NONE  = 7,
   FATAL = 6,
   ERROR = 5,  
   WARN  = 4,
   INFO  = 3,
   DEBUG = 2,
   TRACE = 1
};
input LOGLEVEL       LogLevel    = DEBUG;       // ログレベル


//---input変数（トレードEA用変数）------------------------------------------
input double         Lots        = 0.1;         // ロット数(0.1枚以上)
input ulong          Slipage     = 3.0;         // スリッページ(pips)
input double         Spread      = 1.0;         // スプレッド(pips)


//---input変数（固有変数）------------------------------------------------
input int            MainBollin_Period    = 1120;              // メインボリンジャー（エントリー用）の期間
input double         MainBollin_Entry_Dev = 1.5;               // メインボリンジャーの標準偏差
input int            SubBollin_Period     = 303;               // サブボリンジャー（クローズ用）の期間
input datetime       TradeTime1_Open      = D'09:00:00';       // トレードの開始時間１
input datetime       TradeTime1_Close     = D'23:45:00';       // トレードの終了時間１
input datetime       TradeTime2_Open      = D'03:00:00';       // トレードの開始時間２
input datetime       TradeTime2_Close     = D'06:00:00';       // トレードの終了時間２
input double         MainBollinWidth      = 8.4;               // メインボリンジャーの幅（エントリー時利用）
input double         MaxProfit            = 70.0;              // 最大利益(pips)（注文の利益が達したら注文をクローズさせる）
input double         DayLosCut            = 40.0;              // 一日のロスカット許容量(pips)（許容量以上にロスカットが蓄積された場合、その日はトレードできない）
input float          SpreadMagnification  = 1.5;               // スプレッド幅の倍率（エントリー時に利用）(1.5確)
input ENUM_APPLIED_PRICE   Applied_Price     = PRICE_CLOSE;    // 価格の種類(PRICE_CLOSE:終値, PRICE_OPEN:始値, PRICE_HIGH:高値, PRICE_LOW:低値)


//---グローバル変数---------------------------------------------
// FileOutLogクラス，ログクラスのインスタンス生成
Logger     *logger;
FileOutLog *file;
CTrade     *trade;

// pipsから価格への変換変数
ulong  cal_Slipage                  = 0;     // スリッページ（価格変換用）
double cal_Spread                   = 0;     // スプレッド（価格変換用）
double cal_MainBollinWidth          = 0;     // メインボリンジャーの幅（価格変換用）
double cal_MaxProfit                = 0;     // 最大利益（価格変換用）

// 記録変数
double rec_DayLosCut;               // ロスカット蓄積量
double rec_OutMaxMinPrice;          // 出力用の最大・最小値
int    rec_OutMaxMinTime;           // 出力用の最大・最小値までのバー数
double rec_OpenLosCut;              // エントリー時のロスカット
double rec_OpenSpread;              // エントリー時のスプレッド
double rec_OpenPrice;               // エントリー時の価格
int    rec_OpenPositionBar;         // エントリー時のバー数
MqlDateTime rec_OpenPositionTime;   // エントリー時の時間
bool   rec_OpenDST;                 // エントリー時のDST 

// 指標ハンドル変数
int mainBoll_Entry_Handle;    // メインボリンジャーのハンドル
int subBoll_Handle;           // サブボリンジャーのハンドル

// 指標配列変数
double mainBoll_Entry_High[];    // メインボリンジャーHighをコピーするための配列
double mainBoll_Entry_Low[];     // メインボリンジャーLowをコピーするための配列
double mainBoll_Entry_Middle[];  // メインボリンジャーMiddleをコピーするための配列
double subBoll_Middle[];         // サブボリンジャー　Middleをコピーするための配列

// 共通情報変数
string timeFrameSymbol;          // 銘柄情報
double subBollin_Dev = 0.0;      // サブボリンジャーの標準偏差
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit(){
   // OnInit処理用のprocessIDを発行
   MathSrand(GetTickCount());
   int processID = MathRand();
   
   // 各クラスのインスタンス生成
   logger = new Logger(MagicNumber, LogLevel, "MixBollinger"); 
   file   = new FileOutLog(MagicNumber, LogLevel);
   trade  = new CTrade();
   
   // ログ出力（スタート）
   logger.info(processID, true, "ONINIT", "-");
   
   // 時間足が1分足かどうかを判定
   if(Period() != PERIOD_M1){
      logger.error(processID, false, "ONINIT", "ERROR_TIMEFRAME");
      Alert("【ERROR】1分足で起動してください。");
      return(INIT_FAILED);
   }
   
   // 銘柄情報を取得
   timeFrameSymbol = Symbol();
   
   // tradeクラスのフィールドに登録
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(cal_Slipage);

   // pips数から価格への変換処理
   int symbol_Digits = Digits();
   
   if(symbol_Digits == 3 || symbol_Digits == 5){
      cal_Slipage = int(Slipage * 10);
      if(symbol_Digits == 3){
         cal_Spread                    = Spread                  / 100;
         cal_MaxProfit                 = MaxProfit               / 100;
         cal_MainBollinWidth           = MainBollinWidth         / 100;
      } else if(symbol_Digits==5){
         cal_Spread                    = Spread                  / 10000;
         cal_MaxProfit                 = MaxProfit               / 10000;
         cal_MainBollinWidth           = MainBollinWidth         / 10000;
      }
   }else{
      cal_Spread                    = Spread;
      cal_MaxProfit                 = MaxProfit;
      cal_Slipage                   = int(Slipage);
      cal_MainBollinWidth           = MainBollinWidth;
   }
   
   // 指標ハンドルの生成
   mainBoll_Entry_Handle = iBands(timeFrameSymbol, PERIOD_CURRENT, MainBollin_Period, 0, MainBollin_Entry_Dev, Applied_Price);
   subBoll_Handle        = iBands(timeFrameSymbol, PERIOD_CURRENT, SubBollin_Period , 0, subBollin_Dev       , Applied_Price);
   if(mainBoll_Entry_Handle < 0){
      logger.error(processID, false, "ONINIT", "ERROR_GETHANDLE_MAIN_E");
      Alert("【ERROR】ボリンジャーバンド（メイン）のハンドル取得に失敗しました");
      return(INIT_FAILED);
   }
   if(subBoll_Handle < 0){
      logger.error(processID, false, "ONINIT", "ERROR_GETHANDLE_SUB");
      Alert("【ERROR】ボリンジャーバンド（サブ）のハンドル取得に失敗しました");
      return(INIT_FAILED);
   }
   
   //---ファイルオープン処理-----------------------------------------------------------------------  
   // データファイル名を生成
   string fileName;
   StringConcatenate(fileName, "MixBollinger_", timeFrameSymbol, ".csv"); 
  
   // データファイルが存在するかを取得
   bool existInputFile = file.IsExist(processID, fileName);
  
   // データファイルを開くor作成
   int fileHandle = file.Open(processID, fileName, FILE_READ|FILE_WRITE|FILE_TXT, ',');
   if(file.procResult == 2){
      logger.error(processID, false, "ONINIT", "ERROR_OPEN_FILE(Code:" + IntegerToString(file.ErrorCode) + ")");
      Alert("【ERROR】正常にファイルを開く、あるいはファイルの作成ができませんでした");
      return(INIT_FAILED);
   }
  
   // データファイルが存在する
   if(existInputFile == true){
      // データファイルの最終行を取得（OnTick時の入力の準備）
      file.Seek(processID, 0, SEEK_END);
      if(file.procResult == 2){
         logger.error(processID, false, "ONINIT", "ERROR_SEEK_FILE(Code:" + IntegerToString(file.ErrorCode) + ")");
         Alert("【ERROR】ファイルのポイント移動ができませんでした");
         return(INIT_FAILED);
      }
  
   }else{
      // データファイルにヘッダーを挿入
      file.WriteString(processID, "SystemDate,Date,DST,Week,OpenTime,CloseTime,OpenPrice,ClosePrice,Type,Profit,MaxProfit,Rate,MaxMinTime,LosCut,Spread\r\n");
      
   }
  
  
//---
   // --ログ出力（エンド）
   logger.info(processID, false, "ONINIT", "OK");
   
   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason){
   // OnDeInit処理用のprocessIDを発行
   int processID = MathRand();
   
   // --ログ出力（スタート）
   logger.info(processID, true, "ONDEINIT", "");
   
   //  データファイルを閉じる
   file.Close(processID);
   
   // --ログ出力（エンド）
   if(file.procResult == 2){
      logger.error(processID, false, "ONDEINIT", "ERROR_CLOSE_FILE(Code:" + IntegerToString(file.ErrorCode) + ")");
      Alert("【ERROR】正常にファイルを閉じることができませんでした");
   }else{ 
      logger.info(processID, false, "ONDEINIT", "OK(" + IntegerToString(UninitializeReason()) +")");
   }
   
   // 各クラスのインスタンス削除
   delete file;
   delete logger; 
   delete trade;
}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick(){   
   // OnTick処理用のprocessIDを発行
   int processID = MathRand();
   
   // ログ出力（スタート）
   logger.trace(processID, true, "ONTICK", "");

   // ロウソク数チェック ： バーがメインボリンジャーの周期より少ないか
   int currentNumBars = Bars(timeFrameSymbol, PERIOD_CURRENT);
   if(currentNumBars <= MainBollin_Period){
      logger.trace(processID, false, "ONTICK", "BARCHECK");
      return;
   }
   
   // 日付更新チェック ： 日足のバーが新たに生成されている
   if(NewBar::IsNewBar(timeFrameSymbol, PERIOD_D1)){
      // 一日のロスカット量をリセット
      rec_DayLosCut = 0;
      
      // ファイルへの書き込み
      //file.Flush(processID);
   }
   
   // 現在と1つ前のTick情報を取得(エントリー条件に1つ前のTick情報を用いるため)
   MqlTick tick[2];     // tick[0]:一個前のtick、tick[1]：現在のtick
   if(CopyTicks(timeFrameSymbol, tick, COPY_TICKS_ALL, 0 ,2) == -1){
      logger.error(processID, false, "ONTICK", "COPYTICK");
      return;
   }
   
   // ボリンジャーバンドの値を取得
   if(CopyBuffer(mainBoll_Entry_Handle, UPPER_BAND, 0, 1, mainBoll_Entry_High) == -1){
      logger.error(processID, false, "ONTICK", "ERROR_COPYBOLLIN_HIGH(" + IntegerToString(GetLastError()) + ")");
      return;
   }
   if(CopyBuffer(mainBoll_Entry_Handle, LOWER_BAND, 0, 1, mainBoll_Entry_Low) == -1){
      logger.error(processID, false, "ONTICK", "ERROR_COPYBOLLIN_LOW(" + IntegerToString(GetLastError()) + ")");
      return;
   }
   if(CopyBuffer(mainBoll_Entry_Handle, BASE_LINE , 0, 1, mainBoll_Entry_Middle) == -1){
      logger.error(processID, false, "ONTICK", "ERROR_COPYBOLLIN_MIDDLE(" + IntegerToString(GetLastError()) + ")");
      return;
   }
   if(CopyBuffer(subBoll_Handle       , BASE_LINE , 0, 1, subBoll_Middle) == -1){
      logger.error(processID, false, "ONTICK", "ERROR_COPYBOLLIN_SUB(" + IntegerToString(GetLastError()) + ")");
      return;
   }
   
   // 起動同EA、同銘柄のオーダー数を取得する処理
   if(TradePosition::TradePositionNum(timeFrameSymbol, MagicNumber) == 0){
   
      /*
       * ポジションを持っていない場合の処理
       */
      
      // トレード可能時刻のチェック(Time_Switch)
      if(IsTradeTime(TradeTime1_Open, TradeTime1_Close) == false){
         if(IsTradeTime(TradeTime2_Open, TradeTime2_Close) == false){
            logger.trace(processID, false, "ONTICK", "OPEN_TRADETIME");
            return;
         }
      }
      
      // ボリンジャーバンドの幅を計算
      double bollinWidth = mainBoll_Entry_High[0] - mainBoll_Entry_Middle[0];
      
      // スプレッドのチェック
      double spread = tick[1].ask - tick[1].bid;
      if(spread > cal_Spread){
         logger.trace(processID, false, "ONTICK", "WIDESPREAD");
         return;
      }
      
      // スプレッドが大きく、ボリンジャーの幅が小さくないかチェック
      if(bollinWidth <= spread * SpreadMagnification){
         logger.trace(processID, false, "ONTICK", "WIDESPREADTHANBOLLIN");
         return;
      }
      
      // 一日のロスカット量が許容量を超えていないかチェック(DayLosCut_Switch)
      if(DayLosCut < rec_DayLosCut){
         logger.trace(processID, false, "ONTICK", "OPEN_DAYLOSCUT");
         return;
      }
      
      // トレード可能であるボリンジャーバンドの幅かのチェック(EntryLosCut_Switch)
      if(cal_MainBollinWidth <= bollinWidth){
         logger.trace(processID, false, "ONTICK", "OPEN_WIDEBAND");
         return;
      }
      
      // 1つ前のTick情報の価格がボリンジャーバンドの内側にであるかをチェック(RedBolin_Switch)
      if((tick[0].ask > mainBoll_Entry_High[0]) || (mainBoll_Entry_Low[0] > tick[0].bid)){
         logger.trace(processID, false, "ONTICK", "OPEN_INSIDEBAND");
         return;
      }
      
      // サブボリンジャーがメインボリンジャーの内側にいるかをチェック（サブボリンジャーが発散している状態でエントリーしないように）(InsideWhite_Switch)
      if((subBoll_Middle[0] > mainBoll_Entry_High[0]) || (mainBoll_Entry_Low[0] > subBoll_Middle[0])){
         logger.trace(processID, false, "ONTICK", "OPEN_SUBBOLINNINSIDE");
         return;
      }

      /*
       * エントリー処理
       */
       
      // メインボリンジャー Highより高値を付けたら買い処理
      if(mainBoll_Entry_High[0] <= tick[1].ask){
         if(trade.Buy(Lots, timeFrameSymbol) == false){ 
            logger.error(processID, false, "ONTICK", "ERROR_OPEN_BUY_OPENPOSITION(" + IntegerToString(GetLastError()) + ")");
            return;
         }
         // エントリー時の情報を記録
         RecordOpenData(bollinWidth, currentNumBars, spread);
         logger.info(processID, false, "ONTICK", "OPEN_BUY_OPENPOSITION");
         return;
      }
      
      // メインボリンジャー Lowより安値を付けたら売り処理
      if(mainBoll_Entry_Low[0] >= tick[1].bid){
         if(trade.Sell(Lots, timeFrameSymbol) == false){
            logger.error(processID, false, "ONTICK", "ERROR_OPEN_SELL_OPENPOSITION(" + IntegerToString(GetLastError()) + ")");
            return;
         }
         RecordOpenData(bollinWidth, currentNumBars, spread);
         logger.info(processID, false, "ONTICK", "OPEN_SELL_OPENPOSITION");
         return;
      }
      
      logger.trace(processID, false, "ONTICK", "OPEN_NOTOPENPOSITION");
      return;
      
      
   }else{
   
      /*
       * ポジションを持っている場合の処理
       */
      
      // 保有ポジションのタイプ（買い）をチェック
      if(trade.RequestType() == ORDER_TYPE_BUY){
         
         /*
         　* 保有ポジションが買いの場合
         　*/
         
         // ファイル出力用に最大値とそれまでの期間を記録する処理
         if(rec_OutMaxMinPrice < tick[1].bid){
            rec_OutMaxMinPrice = tick[1].bid;
            rec_OutMaxMinTime = currentNumBars - rec_OpenPositionBar;
         }
         
         // 利益が指定の最大量に達しているかのチェック
         if(tick[1].bid - trade.ResultPrice() >= cal_MaxProfit){
            if(PositionCloseOperation(processID, ORDER_TYPE_BUY, cal_Slipage) == false){
               logger.error(processID, false, "ONTICK", "ERROR_CLOSE_BUY_CLOSEPOSITION(" + IntegerToString(GetLastError()) + ")");
               return; 
            }
            logger.info(processID, false, "ONTICK", "CLOSE_BUY_MAXPROFIT");
            return;
         }
         
         // 損切りチェック
         if(mainBoll_Entry_Middle[0] >= tick[1].bid){
           if(PositionCloseOperation(processID, ORDER_TYPE_BUY, cal_Slipage) == false){
               logger.error(processID, false, "ONTICK", "ERROR_CLOSE_BUY_CLOSEPOSITION(" + IntegerToString(GetLastError()) + ")");
               return; 
           }
           logger.info(processID, false, "ONTICK", "CLOSE_BUY_LOSCUT");
           return;
         } 

         // 利食いチェック
         if(IsTakeProffit(ORDER_TYPE_BUY, trade.ResultPrice(), mainBoll_Entry_High[0], mainBoll_Entry_Low[0], subBoll_Middle[0]) == true){
            if(PositionCloseOperation(processID, ORDER_TYPE_BUY, cal_Slipage) == false){
               logger.error(processID, false, "ONTICK", "ERROR_CLOSE_BUY_CLOSEPOSITION");
               return;
            }
            logger.info(processID, false, "ONTICK", "CLOSE_BUY_TAKEPROFIT");
            return;
         }
         
         logger.trace(processID, false, "ONTICK", "CLOSE_BUY_NOTCLOSEPOSITION");
      
      
      // 保有ポジションのタイプ（売り）をチェック
      }else if(trade.RequestType() == ORDER_TYPE_SELL){
         
         /*
         　* 保有ポジションが売りの場合
         　*/
         
         // ファイル出力用に最大値とそれまでの期間を記録する処理
         if(rec_OutMaxMinPrice > tick[1].ask){
            rec_OutMaxMinPrice = tick[1].ask;
            rec_OutMaxMinTime = currentNumBars - rec_OpenPositionBar;
         }
         
         // 利益が指定の最大量に達したら注文をクローズするチェック
         if(trade.ResultPrice() - tick[1].ask >= cal_MaxProfit){
            if(PositionCloseOperation(processID, ORDER_TYPE_SELL, cal_Slipage) == false){
               logger.error(processID, false, "ONTICK", "ERROR_CLOSE_SELL_CLOSEPOSITION(" + IntegerToString(GetLastError()) + ")");
               return; 
            }
            logger.info(processID, false, "ONTICK", "CLOSE_SELL_MAXPROFIT");
            return;
         }
         
         // 損切りチェック
         if(mainBoll_Entry_Middle[0] <= tick[1].ask){
           if(PositionCloseOperation(processID, ORDER_TYPE_SELL, cal_Slipage) == false){
               logger.error(processID, false, "ONTICK", "ERROR_CLOSE_SELL_CLOSEPOSITION(" + IntegerToString(GetLastError()) + ")");
               return; 
           }
           logger.info(processID, false, "ONTICK", "CLOSE_SELL_LOSCUT");
           return;
         }
             
         // 利確チェック
         if(IsTakeProffit(ORDER_TYPE_SELL, trade.ResultPrice(), mainBoll_Entry_High[0], mainBoll_Entry_Low[0], subBoll_Middle[0]) == true){
            if(PositionCloseOperation(processID, ORDER_TYPE_SELL, cal_Slipage) == false){
               logger.error(processID, false, "ONTICK", "ERROR_CLOSE_SELL_CLOSEPOSITION(" + IntegerToString(GetLastError()) + ")");
               return; 
            }
            logger.info(processID, false, "ONTICK", "CLOSE_SELL_TAKEPROFIT");
            return;
         }
         
         logger.trace(processID, false, "ONTICK", "CLOSE_SELL_NOTCLOSEPOSITION");
      }
   }
}





// 現在時刻でトレード可能かチェックする処理
bool IsTradeTime(datetime timeOpen, datetime timeClose){
   MqlDateTime timeOpenStrc;
   MqlDateTime timeCloseStrc;
   TimeToStruct(timeOpen, timeOpenStrc);
   TimeToStruct(timeClose, timeCloseStrc);
   
   MqlDateTime currntStrc;
   TimeCurrent(currntStrc);
   
   if(timeOpenStrc.hour <= currntStrc.hour && currntStrc.hour <= timeCloseStrc.hour){
      if(timeOpenStrc.hour < currntStrc.hour && currntStrc.hour < timeCloseStrc.hour){
         return true;
         
      }else if(timeOpenStrc.hour == currntStrc.hour){
         if(timeOpenStrc.min <= currntStrc.min){
            return true;
         }
         
      }else if(timeCloseStrc.hour == currntStrc.hour){
         if(timeCloseStrc.min > currntStrc.min){
            return true;
         }
      }
   }
   
   return false;
   
}

// 利確可能かチェックする処理
// HACK:必要のない条件がないかえを確認したい（条件が少々複雑なため）
bool IsTakeProffit(ENUM_ORDER_TYPE type, double price, double boll_entry_high, double boll_entry_low, double subBoll_middle){
   MqlTick tick;
   SymbolInfoTick(timeFrameSymbol, tick);
   
   switch(type){
      case ORDER_TYPE_BUY:
         // 利益が0以上であるか
         if(price <= tick.bid){
            // サブボリンジャーがチェック用のボリンジャーバンドの外側にあるか
            if(boll_entry_high <= subBoll_middle){
               // 売値がサブボリンジャーより安値を付けた場合利食い
               if(subBoll_middle >= tick.bid){
                  return true;
               }
            }
         }
         break;
      
      case ORDER_TYPE_SELL:
         // 利益が0以上であるか
         if(price >= tick.ask){
            // サブボリンジャーがチェック用のボリンジャーバンドの外側にあるか
            if(boll_entry_low >= subBoll_middle){
               // 売値がサブボリンジャーより安値を付けた場合利食い
               if(subBoll_middle <= tick.ask){
                  return true;
               }
            }
         }
         break;
   }
   
   return false;
}

// トレード処理が成功したときにオープン時の情報を記録する処理
void RecordOpenData(double bollinWidth, int currentNumBars, double spread){
   MqlDateTime current;
   TimeCurrent(current);

   rec_OutMaxMinPrice = trade.ResultPrice();
   rec_OutMaxMinTime = 0;
   rec_OpenLosCut = bollinWidth;
   rec_OpenSpread = spread;
   rec_OpenPrice = trade.ResultPrice();
   rec_OpenPositionBar = currentNumBars;
   rec_OpenPositionTime = current; 
   rec_OpenDST = DST::IsDST(IsUK, StructToTime(current));
   // rec_Expansion_Flag = expansion_Flag;
}

// ポジションのクローズ処理
bool PositionCloseOperation(int processID, ENUM_ORDER_TYPE type, ulong slipage){
     
   if(trade.PositionClose(timeFrameSymbol, slipage) == false){
      return false;
   }
   
   string outputData = FormatOutputData(type);
   
   // データファイルへ書き込み
   file.WriteString(processID, outputData);
   return true;
}

// ポジションのクローズ処理時の出力文字列の生成
string FormatOutputData(ENUM_ORDER_TYPE type){
   
   // 'Date'と'Time'の文字列化
   string entryDay;
   StringConcatenate(entryDay, rec_OpenPositionTime.year, ".", IntegerToString(rec_OpenPositionTime.mon,2,'0'), ".", IntegerToString(rec_OpenPositionTime.day,2,'0'));
   string entryTime;
   StringConcatenate(entryTime, IntegerToString(rec_OpenPositionTime.hour,2,'0'), ":", IntegerToString(rec_OpenPositionTime.min,2,'0'));
   
   MqlDateTime closeTimeStruct;
   TimeCurrent(closeTimeStruct);
   string closeTime;
   // クローズが日にちをまたいだ場合48時間表記にする
   if(closeTimeStruct.hour < rec_OpenPositionTime.hour){   
      StringConcatenate(closeTime, IntegerToString(closeTimeStruct.hour + 24,2,'0'), ":", IntegerToString(closeTimeStruct.min,2,'0'));
   }else{
      StringConcatenate(closeTime, IntegerToString(closeTimeStruct.hour,2,'0'), ":", IntegerToString(closeTimeStruct.min,2,'0'));
   }
   
   datetime systemOpenTime = StructToTime(rec_OpenPositionTime);
   
   // DSTの文字変換
   char cDST;
   if(rec_OpenDST == true){
      cDST = 'Y';
   }else{
      cDST = 'N';
   }
   
   // expansion_Flagの文字変換
//   char cExpansion;
//   if(rec_Expansion_Flag == true){
//      cExpansion = 'Y';
//   }else{
//      cExpansion = 'N';
//   }
   
   // 利益と最大利益に対する割合を計算
   double closePrice = trade.ResultPrice();
   double profit = 0;
   double profit_max = 0;
   double rate = 0;
   
   if(type == ORDER_TYPE_BUY){
      profit = closePrice - rec_OpenPrice;
      profit_max = rec_OutMaxMinPrice - rec_OpenPrice;
      if(profit_max != 0){
         rate = profit / profit_max * 100;
      }else{
         rate = 0;
      }
   }else if(type == ORDER_TYPE_SELL){
      profit = rec_OpenPrice - closePrice;
      profit_max = rec_OpenPrice - rec_OutMaxMinPrice;
      if(profit_max != 0){
         rate = profit / profit_max * 100;
      }else{
         rate = 0;
      }
   }
   
   // クレジットからpip数への変換処理
   double pips_Profit = 0;
   double pips_LosCut = 0;
   double pips_Spread = 0;
   double pips_MaxProfit = 0;
   
   int symbol_Digits = Digits();
   string strOpenPrice = DoubleToString(rec_OpenPrice, symbol_Digits);
   string strClosePrice = DoubleToString(closePrice, symbol_Digits);
   if(symbol_Digits == 3 || symbol_Digits == 5){
      if(symbol_Digits == 3){
         pips_Profit = profit * 100;
         pips_Spread = rec_OpenSpread * 100;
         pips_MaxProfit = profit_max * 100;
         pips_LosCut = rec_OpenLosCut * 100;
      } else if(symbol_Digits==5){
         pips_Profit = profit * 10000;
         pips_Spread = rec_OpenSpread * 10000;
         pips_MaxProfit = profit_max * 10000;
         pips_LosCut = rec_OpenLosCut * 10000;
      }
   }else{
      pips_Profit = profit;
      pips_Spread = rec_OpenSpread;
      pips_MaxProfit = profit_max;
      pips_LosCut = rec_OpenLosCut;
   }
   
   // 入力データの文字列化
   string inputData; 
   StringConcatenate(inputData,        
      TimeToString(systemOpenTime), ",",     //システム用日時
      entryDay,                           ",",     //日付
      CharToString(cDST),                 ",",     //サマータイム
      IntegerToString(rec_OpenPositionTime.day_of_week), ",",     //曜日
      entryTime,                          ",",     //エントリー時間
      closeTime,                          ",",     //クローズ時間
      strOpenPrice,                       ",",     //エントリー値
      strClosePrice,                      ",",     //クローズ値
      IntegerToString(type),              ",",     //買い売り
      DoubleToString(pips_Profit,1),      ",",     //利益
      DoubleToString(pips_MaxProfit,1),   ",",     //最大利益
      DoubleToString(rate, 1),            ",",     //最大利益に対する利益の割合
      IntegerToString(rec_OutMaxMinTime), ",",     //最大利益時の時間
      pips_LosCut,                        ",",     //ロスカット            
      pips_Spread,                        "\r\n"); //スプレッド
   
   // 一日のロスカット量に今回トレードの利益を追加
   rec_DayLosCut += pips_Profit;
   
   return inputData;
}