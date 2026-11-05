# Login workers that individual starters run by default.
# CoveredBy lists the group entries that already handle the same application;
# group dispatch adds -NoLogin for those starters so two workers never contend
# for the shared desktop input lock.
@{
    starters = @{
        'start-shinny.ps1'   = @{
            Worker          = 'login-zsqh-clients.ps1'
            ScriptArguments = @('-Apps', 'Q73N')
            CoveredBy       = @('login-zsqh-clients.ps1')
        }
        'start-yongchun.ps1' = @{
            Worker          = 'login-zsqh-clients.ps1'
            ScriptArguments = @('-Apps', 'AlgoMaster')
            CoveredBy       = @('login-zsqh-clients.ps1')
        }
        'start-futubull.ps1' = @{
            # Futubull's own Automatic Login is enabled, so a normal start shows
            # no login screen; cap the fallback wait instead of the 300s default.
            Worker          = 'login-futubull.ps1'
            ScriptArguments = @('-TimeoutSeconds', '90')
            CoveredBy       = @('login-futubull.ps1', 'complete-us-login.ps1')
        }
        'start-schwab.ps1'   = @{
            Worker          = 'login-thinkorswim.ps1'
            ScriptArguments = @()
            CoveredBy       = @('login-thinkorswim.ps1', 'complete-us-login.ps1')
        }
    }
}
