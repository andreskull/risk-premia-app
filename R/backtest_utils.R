# Functions supporting backtesting tabs

library(tidyverse)
library(lubridate)

# Setup backtest =======================

get_monthends <- function(prices_df) {
  prices_df %>% 
      mutate(
        year = year(date),
        month = month(date)
      ) %>%
      group_by(year, month) %>%
      summarise(date = max(date))
}

make_monthly_prices <- function(prices_df, monthends) {
  prices_df %>%
    inner_join(monthends, by = 'date') %>%
    select(ticker, date, close = closeadjusted)
  
}

# Buy equal amount, don't rebalance =====

num_shares <- function(monthlyprices_df, equity) {
  monthlyprices_df %>%
    filter(date == startDate) %>%
    mutate(shares = trunc((equity / 3) / close)) %>%
    select(ticker, shares)
  
}

ew_norebal_positions <- function(monthlyprices_df, num_shares, perShareComm, minCommPerOrder) {
  # calculate positions, exposures, trades, commissions
  
  monthlyprices_df %>%
    inner_join(num_shares, by = 'ticker') %>%
    mutate(exposure = shares * close) %>%
    group_by(ticker) %>%
    mutate(trades = shares - lag(shares)) %>%
    # Initial trade to setup position comes through as NA
    mutate(trades = case_when(is.na(trades) ~ shares, TRUE ~ trades)) %>%
    mutate(tradevalue = trades * close) %>%
    mutate(commission = case_when(abs(trades) * perShareComm > minCommPerOrder ~ abs(trades) * perShareComm, trades == 0 ~ 0, TRUE ~ minCommPerOrder))
}

get_init_cash_bal <- function(positions, inital_equity) {
  positions %>% 
    ungroup() %>%
    filter(date == startDate) %>%
    summarise(cash = inital_equity - sum(exposure) - sum(commission)) %>%
    pull()
}

bind_cash_positions <- function(positions, initial_cash_balance, inital_equity) {
  # bind cash balances to positions df
  
  ticker_temp <- positions %>% distinct(ticker) %>% first() %>% pull()
  
  Cash <- positions %>%
    ungroup() %>%
    filter(ticker == ticker_temp) %>% # just doing this to get the dates
    mutate(
      ticker = 'Cash', 
      date, 
      close = 0, 
      shares = 0, 
      exposure = initial_cash_balance, 
      trades = 0, 
      tradevalue = case_when(date == startDate ~ initial_cash_balance - inital_equity, TRUE ~ 0), 
      commission = 0
    ) 
  
  positions %>%
    # Bind cash balances and sort by date again
    bind_rows(Cash) %>%
    arrange(date)
}

# Charts ================================

stacked_area_chart <- function(positions, title) {
  positions %>% 
    ggplot(aes(x = date, y = exposure, fill = ticker)) +
      geom_area() +
      app_fill_scale +
      labs(
        x = "Date",
        y = "Expsoure Value",
        title = title
      ) 
}

trades_chart <- function(positions, title) {
  positions %>%
    filter(ticker != 'Cash') %>% 
    ggplot(aes(x = date, y = tradevalue, fill = ticker)) +
      geom_bar(stat = 'identity', position = position_dodge()) +
      app_fill_scale +
      labs(
        x = "Date",
        y = "Trade Value",
        title = title
      )
}

comm_chart <- function(positions, title) {
  # Trading cost as $
  
  positions %>%
    filter(ticker != 'Cash') %>% 
    ggplot(aes(x=date, y=commission , fill = ticker)) +
      geom_bar(stat = 'identity') +
      app_fill_scale +
      labs(
        x = "Date",
        y = "Commission",
        title = title
      )
}

comm_pct_exp_chart <- function(positions, title) {
  # Trading cost as % of total exposure in instrument
  
  positions %>%
    filter(ticker != 'Cash') %>% 
    mutate(commissionpct = commission / exposure) %>%
    ggplot(aes(x = date, y = commissionpct , fill = ticker)) +
      geom_bar(stat = 'identity', position = position_dodge()) +
      app_fill_scale +
      labs(
        x = "Date",
        y = "Commission",
        title = title
      )
}

# Performance metrics ===================

calc_ann_turnover <- function(positions, mean_equity) {
  # Calculate as total sell trades divided by mean equity * number of years
  
  totalselltrades <- positions %>%
    filter(
      ticker != 'Cash',
      tradevalue < 0,
      date != startDate
    ) %>%
      summarise(sellvalue = sum(tradevalue)) %>%
      pull() 
  
  if(length(totalselltrades) == 0) {
    return(0)
  } else {
    -totalselltrades / (mean_equity * (year(endDate) - year(startDate)))
  }
}

calc_port_returns <- function(positions) {
  positions %>%
    group_by(date) %>%
    summarise(
      totalequity = sum(exposure),
      totalcommission = sum(commission)    
    ) %>%
    ungroup() %>%
    arrange(date) %>%
    mutate(returns = totalequity / lag(totalequity) - 1)
}

summary_performance <- function(positions, initial_equity) {
  # binds metrics from tidyquant with ours
  
  port_returns <- positions %>%
    calc_port_returns() 
  
  mean_equity <- mean(port_returns$totalequity)
  total_profit <- tail(port_returns, 1)$totalequity - initial_equity
  costs_pct_profit <- sum(port_returns$totalcommission) / total_profit
  
  port_returns %>% 
    tq_performance(Ra = returns, performance_fun = table.AnnualizedReturns) %>% 
    bind_cols(c(
      port_returns %>%
        tq_performance(Ra = returns, performance_fun = table.DownsideRisk) %>%
        select(MaximumDrawdown),
      positions %>% 
        calc_ann_turnover(mean_equity) %>% 
        enframe(name = NULL, value = "Ave.Ann.Turnover"),
      total_profit %>% 
        enframe(name = NULL, value = "Tot.Profit"),
      costs_pct_profit %>% 
        enframe(name = NULL, value = "Costs(pct.Profit)")
    ))
}

combine_port_asset_returns <- function(positions, returns_df) {
  # create df of port and asset returns
  
  positions %>%
    calc_port_returns() %>% 
    select(date, returns) %>%
    mutate(ticker = "Portfolio") %>% 
    bind_rows(returns_df %>% select(ticker, date, returns)) %>% 
    arrange(date)
}

rolling_ann_port_perf <- function(port_returns_df) {
  # rolling performance of portfolio and assets (not asset contribution to portfolio)
  
  port_returns_df %>% 
    group_by(ticker) %>% 
    arrange(date) %>% 
    mutate(
      roll_ann_return = sqrt(12)*roll_mean(returns, width = 12),
      roll_ann_sd = sqrt(12)*roll_sd(returns, width = 12),
      roll_sharpe = roll_ann_return/roll_ann_sd
    ) %>% 
    select(date, ticker, roll_ann_return, roll_ann_sd, roll_sharpe) %>% 
    pivot_longer(cols = c(-ticker, -date), names_to = "metric", values_to = "value")
}

rolling_ann_port_perf_plot <- function(perf_df) {
  metric_names <- as_labeller(c(
    `roll_ann_return` = "Return",
    `roll_ann_sd` = "Volatility",
    `roll_sharpe` = "Sharpe"
  ))
  
  perf_df %>% 
    mutate(ticker = factor(ticker, levels = names(app_cols))) %>%
    ggplot(aes(x = date, y = value, colour = ticker, size = ticker)) +
      geom_line() +
      app_col_scale +
      scale_size_manual(
        values = c(rep(0.6, length(rp_tickers)), 1.2),
        labels = waiver()
      ) +
      facet_wrap(~metric, scales = "free_y", ncol = 1, labeller = metric_names) +
      labs(
        x = "Date",
        y = "Value",
        title = "Rolling Annualised Performance Statistics"
      ) 
}

# Backtest ==============================

# TODO:
# - refactor
# - replace for loop with map_df

share_based_backtest <- function(monthlyprices_df, initial_equity, cap_frequency, rebal_frequency, per_share_Comm, min_comm, rebal_method = "ew") {
  
  stopifnot(rebal_method %in% c("ew", "rp"))
  
  # Create wide data frames for simple share based backtest
  wideprices <- monthlyprices_df %>%
    pivot_wider(date, names_from = 'ticker', values_from = 'close')
  
  if(rebal_method == "rp") {
    widetheosize <- monthlyprices_df %>%
      pivot_wider(date, names_from = 'ticker', values_from = 'theosize_constrained')
  }
  
  rowlist <- list()
  
  Cash <- initial_equity
  sharepos <- c(0,0,0)
  sharevalue <- c(0,0,0)
  equity <- initial_equity
  capEquity <- initial_equity # Sticky equity amount that we're using to allow change cap frequency
  
  # Iterate through prices and backtest
  for (i in 1:(nrow(wideprices))) {
    currentdate <- wideprices[i,1] %>% pull() %>% as.Date()
    currentprice <- as.numeric(wideprices[i,2:4])
    if(rebal_method == "rp") {
      currenttheosize <- as.numeric(widetheosize[i, 2:4])
    }
    equity <- sum(sharepos * currentprice) + Cash
    
    # Update capEquity if it's re-capitalisation rebalance time
    if(cap_frequency > 0) {
      if(i %% cap_frequency == 0) capEquity <- equity 
    }
    
    # Update position sizing if its position rebalance time 
    if (i == 1 | i %% rebal_frequency == 0) {
      if(rebal_method == "ew") {
        targetshares <- trunc((capEquity / 3) / currentprice) 
      } else {
        targetshares <- trunc((capEquity * currenttheosize) / currentprice)  
      }
    }
    
    trades <- targetshares - sharepos
    tradevalue <- trades * currentprice
    commissions <- abs(trades) * per_share_Comm
    commissions[commissions < min_comm] <- min_comm
    
    # Adjust cash by value of trades
    Cash <- Cash - sum(tradevalue) - sum(commissions)
    sharepos <- targetshares
    sharevalue <- sharepos * currentprice
    equity <- sum(sharevalue) + Cash
    
    # Create data frame and add to list
    row_df <- data.frame(
       ticker = c('Cash', colnames(wideprices[2:4])),
       date = rep(currentdate, 4),
       close = c(0,currentprice),
       shares = c(0,sharepos),
       exposure = c(Cash, sharevalue),
       sharetrades = c(0, trades),
       tradevalue = c(-sum(tradevalue), tradevalue),
       commission = c(0, commissions)
    )
    
    rowlist[[i]] <- row_df
    
  }
  
  # Combine list into dataframe
  bind_rows(rowlist)
  
}

# Vol targeting functions ===============

calc_vol_target <- function(prices_df, vol_lookback, target_vol) {
  # Calculate vol target sizing on daily data
  
  prices %>%
    group_by(ticker) %>%
    arrange(date) %>%
    mutate(returns = (closeadjusted / dplyr::lag(closeadjusted)) - 1) %>%
    mutate(vol = slider::slide_dbl(.x = returns, .f = sd, .before = vol_lookback, .complete = TRUE) * sqrt(252)) %>%
    mutate(theosize = lag(target_vol / vol))
}

cap_leverage <- function(vol_targets, max_leverage = 1) {
  # Enforce leverage constraint
  
  total_size <- vol_targets %>%
    group_by(date) %>%
    summarise(totalsize = sum(theosize)) %>%
    mutate(adjfactor = case_when(totalsize > max_leverage ~ max_leverage/totalsize, TRUE ~ 1))
  
  vol_targets %>%
    inner_join(total_size, by = 'date') %>%
    mutate(theosize_constrained = theosize * adjfactor) %>%
    select(ticker, date, closeadjusted, returns, vol, theosize, theosize_constrained) %>%
    na.omit()
}

constrained_sizing_plot <- function(volsized_prices, title) {
  # Plot theoretical constrained sizing as a function of time
  
  volsized_prices %>%
    ggplot(aes(x = date, y = theosize_constrained, fill = ticker)) +
    geom_area() + 
    app_fill_scale +
    labs(
      x = "Date",
      y = "Constrained Sizing", 
      title = title
    )
}
